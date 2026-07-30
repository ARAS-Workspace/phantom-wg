/**
 * Localized user-facing strings. Only text that reaches the client lives
 * here — internal log messages stay English in code.
 */

import { CONFIG } from './config';

export type Locale = 'tr' | 'en';

export interface Translations {
	errors: {
		invalidJson: string;
		validationFailed: string;
		invalidMessages: string;
		emptyMessages: string;
		messageTooLong: string;
		messageEmpty: string;
		invalidRole: string;
		firstMessageNotUser: string;
		lastMessageNotUser: string;
		payloadTooLarge: string;
		endpointNotFound: string;
		methodNotAllowed: string;
		turnstileFailed: string;
		turnstileTokenMissing: string;
		sessionInvalid: string;
		conversationFull: string;
		agentUnavailable: string;
		integrityViolation: string;
		apiError: string;
		emptyResponse: string;
	};
}

const tr: Translations = {
	errors: {
		invalidJson: 'İstek gövdesi geçerli JSON değil.',
		validationFailed: 'İstek doğrulanamadı. Ayrıntılar için details alanına bakın.',
		invalidMessages: 'messages alanı geçerli bir mesaj listesi olmalıdır.',
		emptyMessages: 'En az bir mesaj gönderilmelidir.',
		messageTooLong: 'Mesaj içeriği izin verilen uzunluğu aşıyor.',
		messageEmpty: 'Mesaj içeriği boş olamaz.',
		invalidRole: 'Mesaj rolleri yalnızca user veya assistant olabilir.',
		firstMessageNotUser: 'Sohbet bir kullanıcı mesajı ile başlamalıdır.',
		lastMessageNotUser: 'Sohbetin son mesajı bir kullanıcı mesajı olmalıdır.',
		payloadTooLarge: 'İstek gövdesi çok büyük.',
		endpointNotFound: 'Uç nokta bulunamadı. Kullanılabilir: POST /api/v1/session, POST /api/v1/chat.',
		methodNotAllowed: 'Bu uç nokta yalnızca POST isteklerini kabul eder.',
		turnstileFailed: 'Güvenlik doğrulaması başarısız oldu. Lütfen sayfayı yenileyip tekrar deneyin.',
		turnstileTokenMissing: 'Güvenlik doğrulama anahtarı eksik.',
		sessionInvalid: 'Oturum doğrulanamadı. Lütfen tekrar deneyin.',
		conversationFull: 'Bu konuşma uzunluk sınırına ulaştı. Yeni bir konuşma başlatarak devam edebilirsiniz.',
		agentUnavailable: 'Ajan şu anda yanıt veremiyor. Daha sonra yeni bir konuşma başlatarak tekrar deneyebilirsiniz.',
		integrityViolation: 'Sohbet geçmişi doğrulanamadı. Lütfen yeni bir sohbet başlatın.',
		apiError: 'Yanıt üretilirken bir hata oluştu. Lütfen tekrar deneyin.',
		emptyResponse: 'Üzgünüm, bir yanıt üretemedim. Lütfen sorunuzu farklı bir şekilde sormayı deneyin.',
	},
};

const en: Translations = {
	errors: {
		invalidJson: 'Request body is not valid JSON.',
		validationFailed: 'Request validation failed. See the details field.',
		invalidMessages: 'The messages field must be a valid message list.',
		emptyMessages: 'At least one message is required.',
		messageTooLong: 'Message content exceeds the allowed length.',
		messageEmpty: 'Message content cannot be empty.',
		invalidRole: 'Message roles must be either user or assistant.',
		firstMessageNotUser: 'The conversation must start with a user message.',
		lastMessageNotUser: 'The last message must be a user message.',
		payloadTooLarge: 'Request body is too large.',
		endpointNotFound: 'Endpoint not found. Available: POST /api/v1/session, POST /api/v1/chat.',
		methodNotAllowed: 'This endpoint only accepts POST requests.',
		turnstileFailed: 'Security verification failed. Please refresh the page and try again.',
		turnstileTokenMissing: 'Security verification token is missing.',
		sessionInvalid: 'Session could not be verified. Please try again.',
		conversationFull: 'This conversation has reached its length limit. Start a new conversation to carry on.',
		agentUnavailable: 'The agent cannot answer right now. You can start a new conversation and try again later.',
		integrityViolation: 'The conversation history could not be verified. Please start a new chat.',
		apiError: 'An error occurred while generating the response. Please try again.',
		emptyResponse: "I'm sorry, I couldn't generate a response. Please try rephrasing your question.",
	},
};

const TRANSLATIONS: Record<Locale, Translations> = { tr, en };

/**
 * @example const t = getTranslations(locale);
 */
export function getTranslations(locale: Locale): Translations {
	return TRANSLATIONS[locale];
}

/**
 * Parse an untrusted locale value; falls back to the default.
 * @example const locale = parseLocale(body.locale);
 */
export function parseLocale(value: unknown): Locale {
	return (CONFIG.localization.supportedLocales as readonly string[]).includes(value as string)
		? (value as Locale)
		: CONFIG.localization.defaultLocale;
}
