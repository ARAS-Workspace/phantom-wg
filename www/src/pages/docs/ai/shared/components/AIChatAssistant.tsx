import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BusEventType, CarbonTheme, ChatCustomElement, MessageResponseTypes } from '@carbon/ai-chat';
import type {
  ChatInstance,
  CustomSendMessageOptions,
  HistoryItem,
  LanguagePack,
  MessageRequest,
} from '@carbon/ai-chat';
import type { DeepPartial } from '@carbon/ai-chat';
import { InlineNotification, SkeletonPlaceholder } from '@carbon/react';

import { useIsClient } from '@shared/hooks/useIsClient';
import { useLocale, useTheme } from '@shared/hooks';
import { usePersistedChatHistory } from '../hooks/usePersistedChatHistory';
import type { ApiMessage } from '../hooks/usePersistedChatHistory';
import { translate } from '@shared/translations';

import { AI_WORKER_ENDPOINT, AI_WORKER_ROUTES, TURNSTILE_SITE_KEY, isAiChatConfigured } from './config';
import { clearSession, millisecondsUntilExpiry, readSession, writeSession } from './session';
import { loadTurnstile } from './turnstile';
import './styles/AIChatAssistant.scss';

/**
 * The site agent, in-page.
 *
 * Three things make this more than a chat box wrapper:
 *
 * 1. **One Turnstile solve per session.** The visible widget is answered once,
 *    exchanged for the worker's signed session token, and never shown again
 *    unless that token expires — messages themselves carry no challenge.
 * 2. **Byte-exact history.** The worker hash-chains every turn, so the
 *    assistant text stored locally must equal the concatenation of the
 *    streamed deltas exactly. A turn is stored only once it completes, and an
 *    interrupted one enters neither the local transcript nor the chain — what
 *    it did spend is still recorded, by the gateway the worker calls through.
 * 3. **Client-only.** Carbon AI Chat has no SSR path, so the whole thing sits
 *    behind `useIsClient` with a skeleton in the prerendered HTML.
 */

/**
 * The part of the worker's error envelope this client reads.
 *
 * Three refusals are states rather than failures — the history no longer
 * verifies, the conversation is full, or the agent has no capacity left — and
 * they are told apart by `type`, not by status. A refusal can arrive either as
 * a status or, once the worker has opened the stream, as an `error` event
 * inside it; both are read the same way. `details` carries the
 * per-field reason for a validation refusal, which is what the visitor is shown
 * for those; the envelope's own message only points at the list. `status` is
 * carried for other clients and rendered by none.
 */
interface WorkerErrorBody {
  error?: {
    type?: string;
    message?: string;
    /**
     * Per-field reasons for a validation refusal. The envelope's own message
     * only points at this list, so this is what a visitor is actually shown.
     */
    details?: { field: string; message: string }[];
  };
}

/**
 * Carbon AI Chat only ships a fixed set of dayjs locales and Turkish is not
 * among them; passing `tr` logs a warning and falls back anyway. The setting
 * governs date and number formatting only — the UI language comes from the
 * strings we pass — so map to the supported code explicitly.
 */
const carbonLocale = (locale: string): string => (locale === 'tr' ? 'en' : locale);

/** Structural copy — strips the frozen prototypes Carbon hands back. */
const plainCopy = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

/**
 * Carbon ships an English pack only, so the Turkish UI chrome is supplied
 * here. Only the strings this page can actually surface are translated —
 * the rest fall back to the defaults.
 */
const TURKISH_STRINGS: DeepPartial<LanguagePack> = {
  input_placeholder: 'Bir şeyler yazın...',
  input_ariaLabel: 'Sorunuzu yazın',
  input_buttonLabel: 'Mesajı gönder',
  input_sendingMessage: 'Mesaj gönderiliyor...',
  input_stopResponse: 'Yanıtı durdur',
  message_labelYou: 'Siz {timestamp}',
  message_labelAssistant: '{actorName} {timestamp}',
  messages_responseStopped: 'Yanıt durduruldu',
  general_returnToAssistant: 'Sohbete dön',
  conversationalSearch_streamingIncomplete: 'Bu yanıt tamamlanamadı. Lütfen tekrar deneyin.',
  header_overflowMenu_options: 'Seçenekler',
};

/**
 * Whether the conversation on screen can still be continued.
 *
 * Module scope, for the same reason the session is: switching language swaps
 * the MDX body around this component and remounts it. Held in component state,
 * a conversation the worker has already refused would come back with an open
 * composer, and the visitor would type into a wall they have already hit.
 * Starting a new conversation is what clears it.
 */
let conversationHalted = false;

/**
 * Refusals that end the conversation rather than inviting another attempt: the
 * history no longer verifies, the conversation reached its length, or the agent
 * has no capacity. They arrive either as a status or, when the worker has
 * already opened the stream, as an `error` event inside it — so both paths test
 * against this list.
 */
const HALTING_ERRORS = ['INTEGRITY_VIOLATION', 'CONVERSATION_FULL', 'AGENT_UNAVAILABLE'];

const AIChatAssistant: React.FC = () => {
  const isClient = useIsClient();
  const { locale } = useLocale();
  const { theme } = useTheme();
  const t = translate(locale);

  const { readHistoryItems, readApiContext, addTurn, clearHistory, isLoaded } =
    usePersistedChatHistory();

  // Seeded from the module-scoped session so that remounting this component —
  // which happens whenever the visitor switches language, because the MDX body
  // around it is swapped — does not throw away a session that is still good.
  const [sessionToken, setSessionToken] = useState<string | null>(() => readSession());
  const [gateError, setGateError] = useState<string | null>(null);
  // Set when the worker refuses on a state rather than a fault: the history no
  // longer verifies, the conversation is full, or the agent has no capacity
  // left. The transcript stays readable and the composer closes.
  const [halted, setHaltedState] = useState(() => conversationHalted);
  const setHalted = useCallback((value: boolean): void => {
    conversationHalted = value;
    setHaltedState(value);
  }, []);
  const greetingRef = useRef(t.aiChat.greeting);
  greetingRef.current = t.aiChat.greeting;
  const turnstileRef = useRef<HTMLDivElement>(null);
  const widgetId = useRef<string | null>(null);
  // The turn currently streaming, and whether this instance is still mounted.
  // A locale switch swaps the MDX body around this component, so it can be
  // taken down while a turn is in flight; without these the stream would keep
  // running and write storage that the newly mounted instance had already read.
  const turnAbort = useRef<AbortController | null>(null);
  const mounted = useRef(true);
  // The locale is not in `customSendMessage`'s dep list — a ref is what lets a
  // send read the current value instead of the one it was created with.
  const localeRef = useRef(locale);
  localeRef.current = locale;

  /** Give up the session and put the challenge back, explaining why. */
  const endSession = useCallback((reason: string): void => {
    clearSession();
    setSessionToken(null);
    setGateError(reason);
  }, []);

  /**
   * The Turkish chrome, rebuilt whenever the theme changes.
   *
   * Carbon keeps `strings` outside the config object it watches, but rebuilds
   * its derived language pack from the English default whenever anything in
   * that config does change — and `injectCarbonTheme` is in it. Its own effect
   * for `strings` only re-runs when the prop's identity changes, so a stable
   * constant would be applied once and silently dropped the first time anything
   * in that config moved. Both things this page can change are in it —
   * `injectCarbonTheme` and `isReadonly` — so a fresh object for either is what
   * puts the pack back.
   */
  const chatStrings = useMemo(
    () => (locale === 'tr' ? { ...TURKISH_STRINGS } : undefined),
    [locale, theme, halted]
  );

  const configured = isAiChatConfigured();

  /**
   * Exchange a solved Turnstile token for the worker's session token.
   *
   * A Turnstile token is single-use, so a failed exchange has to reset the
   * widget: the one on screen has already fired its callback and will not
   * produce another token, leaving the visitor with a challenge that cannot be
   * solved and no way back short of reloading.
   */
  const openSession = useCallback(
    async (turnstileToken: string): Promise<void> => {
      const failGate = (message: string): void => {
        setGateError(message);
        if (window.turnstile && widgetId.current) {
          try {
            window.turnstile.reset(widgetId.current);
          } catch {
            // Widget already gone; the gate error still explains the failure.
          }
        }
      };

      try {
        const response = await fetch(`${AI_WORKER_ENDPOINT}${AI_WORKER_ROUTES.session}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ turnstileToken, locale: localeRef.current }),
        });
        if (!response.ok) {
          const body = (await response.json().catch(() => ({}))) as WorkerErrorBody;
          failGate(body.error?.message ?? t.aiChat.errors.sessionFailed);
          return;
        }
        const { token, expiresAt } = (await response.json()) as { token: string; expiresAt: number };
        if (!writeSession(token, expiresAt)) {
          // The session is already spent. Re-rendering the challenge would only
          // earn another one just like it, so say so and stop.
          setGateError(t.aiChat.errors.sessionFailed);
          return;
        }
        setSessionToken(token);
        setGateError(null);
      } catch {
        failGate(t.aiChat.errors.network);
      }
    },
    [t.aiChat.errors.network, t.aiChat.errors.sessionFailed]
  );

  // Render the visible widget until a session exists. Turnstile cannot restyle
  // an existing widget, so a theme change tears this one down and renders a new
  // one — a challenge already in progress is lost with it. That is the cheaper
  // side: the alternative leaves a light-palette challenge sitting in a dark
  // page for the rest of the session.
  useEffect(() => {
    if (!isClient || !configured || sessionToken !== null) return;

    const render = () => {
      if (!window.turnstile || !turnstileRef.current || widgetId.current) return;
      try {
        widgetId.current = window.turnstile.render(turnstileRef.current, {
          sitekey: TURNSTILE_SITE_KEY,
          theme: theme === 'g100' ? 'dark' : 'light',
          callback: (token: string) => {
            void openSession(token);
          },
          'error-callback': () => setGateError(t.aiChat.errors.turnstile),
          'expired-callback': () => {
            if (window.turnstile && widgetId.current) window.turnstile.reset(widgetId.current);
          },
        });
      } catch {
        setGateError(t.aiChat.errors.turnstile);
      }
    };

    const disposeLoader = loadTurnstile(render, () => setGateError(t.aiChat.errors.turnstile));

    return () => {
      disposeLoader();
      if (window.turnstile && widgetId.current) {
        try {
          window.turnstile.remove(widgetId.current);
        } catch {
          // Widget already gone.
        }
      }
      widgetId.current = null;
    };
  }, [isClient, configured, sessionToken, theme, openSession, t.aiChat.errors.turnstile]);

  // Hand the session back before the worker refuses it. Without this the only
  // thing that discovers the hour is up is a real message, which is then spent
  // on a 401 — the visitor loses what they typed to learn that they have to
  // solve the challenge again.
  useEffect(() => {
    if (sessionToken === null) return;

    const remaining = millisecondsUntilExpiry();
    if (remaining === null) return;
    if (remaining <= 0) {
      endSession(t.aiChat.errors.sessionExpired);
      return;
    }

    const timer = window.setTimeout(() => endSession(t.aiChat.errors.sessionExpired), remaining);
    return () => window.clearTimeout(timer);
  }, [sessionToken, endSession, t.aiChat.errors.sessionExpired]);

  // The flag is raised in the effect body, not left to the initial ref value.
  // React runs setup, cleanup, then setup again on mount in development, so a
  // ref only ever lowered would stay lowered for the rest of the component's
  // life — and every completed turn would be discarded below as one that
  // arrived after the widget went away, which is exactly what stopped
  // development builds from persisting anything at all.
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      turnAbort.current?.abort();
    };
  }, []);

  /**
   * Restore the transcript Carbon should show when the chat mounts.
   *
   * The items are cloned first: Carbon freezes the message objects it hands
   * out, and hydration writes its own `history` field onto whatever it gets
   * back — handing the frozen originals over throws.
   */
  const customLoadHistory = useCallback(
    async (): Promise<HistoryItem[]> => plainCopy(readHistoryItems()),
    [readHistoryItems]
  );

  /**
   * "New conversation" has to clear our copies too, otherwise the widget
   * starts empty while the worker still sees the old chain — and the first
   * message of the "new" conversation would fail to anchor. The greeting
   * comes back on its own: an empty conversation triggers a fresh welcome
   * request, which `customSendMessage` answers.
   */
  const onBeforeRender = useCallback(
    (instance: ChatInstance): void => {
      instance.on({
        type: BusEventType.PRE_RESTART_CONVERSATION,
        handler: () => {
          clearHistory();
          // A full conversation is fixed by starting another one; if capacity
          // is what ran out, the next message simply halts again.
          setHalted(false);
        },
      });
    },
    [clearHistory]
  );

  /**
   * One turn: POST the conversation, stream deltas into the transcript, and
   * persist exactly what was streamed.
   */
  const customSendMessage = useCallback(
    async (request: MessageRequest, options: CustomSendMessageOptions, instance: ChatInstance): Promise<void> => {
      const userText = request.input?.text ?? '';

      // An empty conversation makes Carbon send a silent welcome request
      // (`input.text: ""`, `history.is_welcome_request`). It waits for an
      // answer like any other message, so returning early here is what left
      // the loading indicator running with nothing in flight. Answering it is
      // also how the greeting reappears after a reset — and it never touches
      // the worker, so it stays out of the integrity chain.
      if (!userText) {
        await instance.messaging.addMessageChunk({
          final_response: {
            output: { generic: [{ response_type: MessageResponseTypes.TEXT, text: greetingRef.current }] },
          },
        });
        return;
      }

      // Expiry is normally caught by the timer above; this covers the case
      // where the deadline passed while the tab was suspended. The explanation
      // goes on the gate rather than into the transcript — the widget is about
      // to be replaced by the challenge, taking any message in it along.
      const token = readSession();
      if (token === null) {
        endSession(t.aiChat.errors.sessionExpired);
        return;
      }

      const messages: ApiMessage[] = [...readApiContext(), { role: 'user', content: userText }];
      // Two ids, both minted here and used from the first chunk to the stored
      // transcript. `responseId` names the answer as a whole: Carbon ignores
      // any chunk it cannot attribute to a response, so without it the deltas
      // are dropped and the answer only appears once the stream ends.
      // `itemId` names the one text item inside it, which is what lets the
      // partial chunks merge in place instead of remounting.
      const responseId = crypto.randomUUID();
      const itemId = crypto.randomUUID();
      let streamed = '';

      // One controller for this turn, aborted either by Carbon's stop button or
      // by this component going away.
      const turn = new AbortController();
      turnAbort.current = turn;
      if (options.signal.aborted) turn.abort();
      else options.signal.addEventListener('abort', () => turn.abort(), { once: true });

      /**
       * End the turn with a message instead of an answer. It closes the
       * in-flight response rather than adding a second one, so a stream that
       * failed halfway does not leave a half-written answer above the error.
       */
      const fail = async (message: string): Promise<void> => {
        await instance.messaging.addMessageChunk({
          final_response: {
            id: responseId,
            request_id: request.id,
            thread_id: request.thread_id,
            output: {
              generic: [
                {
                  response_type: MessageResponseTypes.TEXT,
                  text: message,
                  streaming_metadata: { id: itemId },
                },
              ],
            },
          },
        });
      };

      try {
        // The locale rides on the query string as well as in the body. The
        // worker refuses an over-length conversation before it reads the body,
        // and that refusal is shown to the visitor, so it needs a locale it can
        // read first.
        const chatUrl = `${AI_WORKER_ENDPOINT}${AI_WORKER_ROUTES.chat}?locale=${localeRef.current}`;
        const response = await fetch(chatUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
          body: JSON.stringify({ messages, locale: localeRef.current }),
          signal: turn.signal,
        });

        if (!response.ok || !response.body) {
          const body = (await response.json().catch(() => ({}))) as WorkerErrorBody;
          if (response.status === 401) {
            // The session lapsed despite the timer — drop back to the gate and
            // explain there, not in a transcript that is about to be unmounted.
            endSession(t.aiChat.errors.sessionExpired);
            return;
          }
          // Three refusals are states, not faults: this conversation cannot be
          // continued (its history no longer verifies, or it reached its
          // length), or the agent has no capacity left. None of them is
          // worth retrying, so the composer closes and the message says why.
          // Nothing is erased here — clearing a conversation is the visitor's
          // to do, through "New conversation" in the header.
          if (body.error?.type !== undefined && HALTING_ERRORS.includes(body.error.type)) {
            await fail(body.error.message ?? t.aiChat.errors.generic);
            setHalted(true);
            return;
          }
          // A validation refusal names its reason per field and leaves the
          // envelope's message pointing at that list — no use to a visitor.
          // Show the reason itself when there is exactly one.
          const details = body.error?.details;
          await fail(
            details?.length === 1 ? details[0].message : (body.error?.message ?? t.aiChat.errors.generic)
          );
          return;
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let streamError: string | null = null;
        let streamHalts = false;
        // The worker emits `done` only after the turn has been written to its
        // integrity chain. Transport EOF proves nothing on its own, so this is
        // what separates a finished turn from a connection that simply ended.
        let completed = false;

        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          // SSE frames are separated by a blank line.
          const frames = buffer.split('\n\n');
          buffer = frames.pop() ?? '';

          for (const frame of frames) {
            const eventLine = frame.split('\n').find((line) => line.startsWith('event: '));
            const dataLine = frame.split('\n').find((line) => line.startsWith('data: '));
            if (!eventLine || !dataLine) continue;

            const event = eventLine.slice(7).trim();
            const data: unknown = JSON.parse(dataLine.slice(6));

            if (event === 'delta') {
              const { text } = data as { text: string };
              streamed += text;
              // Carbon joins partial chunks, so each chunk carries the delta.
              await instance.messaging.addMessageChunk({
                streaming_metadata: { response_id: responseId },
                partial_item: {
                  response_type: MessageResponseTypes.TEXT,
                  text,
                  // `cancellable` is what puts the stop button on screen. The
                  // worker treats the disconnect correctly — the turn never
                  // enters the chain, and what it cost is recorded by the
                  // gateway either way — so there is nothing to undo on this
                  // side either.
                  streaming_metadata: { id: itemId, cancellable: true },
                },
              });
            } else if (event === 'done') {
              completed = true;
            } else if (event === 'error') {
              // A refusal can arrive here rather than as a status: the worker
              // opens the SSE response before it calls the model, so anything
              // the model or the gateway in front of it refuses is reported
              // inside the stream. The type is read for the same reason it is
              // read from a status response — it is what separates a refusal
              // worth retrying from one that ends the conversation.
              const body = data as WorkerErrorBody;
              streamError = body.error?.message ?? t.aiChat.errors.generic;
              streamHalts = body.error?.type !== undefined && HALTING_ERRORS.includes(body.error.type);
            }
          }
        }

        if (streamError !== null) {
          await fail(streamError);
          if (streamHalts) setHalted(true);
          return;
        }

        if (!completed) {
          // The stream stopped without the worker confirming the turn. Storing
          // it anyway would leave a transcript the worker's chain does not
          // recognise, and every later message in this conversation would be
          // rejected as a forgery.
          await fail(t.aiChat.errors.incomplete);
          return;
        }

        // Close the item first, then the response: without the complete_item
        // the widget keeps showing its streaming indicator after the last
        // delta, because nothing told it that item was finished.
        await instance.messaging.addMessageChunk({
          streaming_metadata: { response_id: responseId },
          complete_item: {
            response_type: MessageResponseTypes.TEXT,
            text: streamed,
            streaming_metadata: { id: itemId },
          },
        });

        await instance.messaging.addMessageChunk({
          final_response: {
            id: responseId,
            request_id: request.id,
            thread_id: request.thread_id,
            output: {
              generic: [
                {
                  response_type: MessageResponseTypes.TEXT,
                  text: streamed,
                  streaming_metadata: { id: itemId },
                },
              ],
            },
          },
        });

        // Persist only after a complete answer, and exactly as streamed — and
        // only while this instance is still the one on screen. A turn that
        // finishes after the component went away would write over what its
        // replacement has already read. The abort check covers the narrower
        // case of "New conversation" landing while these last chunks are being
        // drawn: Carbon clears the stored copies from its restart handler and
        // then cancels this turn, so writing here would put the turn the
        // visitor just discarded back into storage they believe is empty.
        if (!mounted.current || turn.signal.aborted) return;

        addTurn(
          [
            // `request` is one of Carbon's frozen objects — persist a copy.
            { message: plainCopy(request), time: new Date().toISOString() },
            {
              // Stored under the same id it was displayed with. The id is what
              // Carbon keys the restored transcript by: without one, every
              // stored answer shares the same empty key, they collapse into a
              // single slot, and the whole transcript is re-rendered inside it
              // under duplicate React keys. `request_id` keeps the pair
              // together.
              message: {
                id: responseId,
                request_id: request.id,
                thread_id: request.thread_id,
                output: {
                  generic: [{ response_type: MessageResponseTypes.TEXT, text: streamed }],
                },
              },
              time: new Date().toISOString(),
            },
          ],
          [
            { role: 'user', content: userText },
            { role: 'assistant', content: streamed },
          ]
        );
      } catch (error) {
        // Abort — the stop button, or leaving the page. The turn is not stored:
        // the worker never wrote it to the chain either, so storing it here
        // would leave a transcript the next message cannot anchor to. What was
        // already streamed stays on screen until the page is reloaded, marked
        // as stopped so the widget settles instead of streaming forever.
        if (turn.signal.aborted || (error instanceof DOMException && error.name === 'AbortError')) {
          // Nothing more to draw once the widget is gone.
          if (streamed.length > 0 && mounted.current) {
            await instance.messaging.addMessageChunk({
              streaming_metadata: { response_id: responseId },
              complete_item: {
                response_type: MessageResponseTypes.TEXT,
                text: streamed,
                streaming_metadata: { id: itemId, stream_stopped: true },
              },
            });
          }
          return;
        }
        await fail(t.aiChat.errors.network);
      }
    },
    [
      addTurn,
      endSession,
      readApiContext,
      t.aiChat.errors.generic,
      t.aiChat.errors.incomplete,
      t.aiChat.errors.network,
      t.aiChat.errors.sessionExpired,
    ]
  );

  if (!configured) {
    return (
      <div className="ai-chat">
        <InlineNotification kind="info" lowContrast hideCloseButton title={t.aiChat.unavailable} subtitle={t.aiChat.unavailableHint} />
      </div>
    );
  }

  // Prerender and first paint: a skeleton the same size as the chat, so the
  // page does not jump when the widget mounts.
  if (!isClient || !isLoaded) {
    return (
      <div className="ai-chat">
        <SkeletonPlaceholder className="ai-chat__skeleton" />
      </div>
    );
  }

  // The challenge stands alone, centred in a box the size of the chat it
  // replaces, so solving it does not shift the page.
  if (sessionToken === null) {
    return (
      <div className="ai-chat">
        <div className="ai-chat__gate">
          <div className="ai-chat__turnstile" ref={turnstileRef} />
          {gateError !== null && (
            <InlineNotification
              kind="error"
              lowContrast
              hideCloseButton
              // Carbon defaults notifications to role="status" (polite). This
              // one appears in place of a challenge the visitor is waiting on,
              // so it has to interrupt rather than queue behind other output.
              role="alert"
              title={t.aiChat.errors.title}
              subtitle={gateError}
            />
          )}
        </div>
      </div>
    );
  }

  return (
    <div className="ai-chat">
      <ChatCustomElement
        className="ai-chat__element"
        messaging={{ customSendMessage, customLoadHistory }}
        locale={carbonLocale(locale)}
        // The chat lives in a shadow root: most of it picks up the host's
        // Carbon tokens, but the code-block styles inside it do not, so the
        // theme is passed explicitly instead of inherited.
        injectCarbonTheme={theme === 'g100' ? CarbonTheme.G100 : CarbonTheme.WHITE}
        // On mobile Carbon otherwise switches the widget into its own
        // full-viewport treatment, which fights an element embedded in the
        // page and pushes the layout wider than the screen.
        disableCustomElementMobileEnhancements
        // Answers are model output rendered as markdown; without this Carbon
        // passes any HTML in them straight through.
        shouldSanitizeHTML
        isReadonly={halted}
        strings={chatStrings}
        assistantName={t.aiChat.assistantName}
        header={{
          title: t.aiChat.header.title,
          showRestartButton: true,
          // The chat is embedded in the page with no launcher, so minimizing
          // it would leave an empty box and no way back.
          hideMinimizeButton: true,
          // Carbon's AI slug opens an "IBM watsonx" explainer, which is not
          // what is running here.
          showAiLabel: false,
        }}
        launcher={{ isOn: false }}
        openChatByDefault
        onBeforeRender={onBeforeRender}
      />
    </div>
  );
};

export default AIChatAssistant;
