-- noinspection SqlDialectInspectionForFile

-- Migration: Initial schema
-- Version: 0001
--
-- One table, and what it is NOT is half the design.
--
-- conversation_logs is the record and the proof. Each row is one turn: what was
-- asked, what was answered, and the hashes that make the conversation it belongs
-- to tamper-evident. There is no conversations table — a conversation is the set
-- of rows sharing a chain_id. The chain is minted on the first message and
-- inherited by every later turn through context_hash, which is why that index is
-- UNIQUE: it is the lookup that decides whether a client-sent history is one
-- this worker actually produced.
--
-- There is no usage table either. Nothing here meters spend, because the worker
-- reaches the model only through AI Gateway, which holds the budget, the rate
-- limit and the key that pays for the call. A second, coarser copy of that
-- accounting used to live here and disagreed with the bill: it counted tokens
-- while the charge is money, and it recorded cache reads at ten times their
-- cost. The per-turn tokens_in/tokens_out below are the record of what a
-- conversation cost, not a meter anything reads back.
--
-- The set of rows in a chain is a tree, not a list, and reading it back has to
-- account for it. Any client holding a conversation can continue it, so two tabs
-- open on the same conversation both anchor on the same context_hash row, both
-- compute the same block_index, and both insert. block_index is therefore depth
-- along a branch, not a unique position: one chain_id may hold sibling rows at
-- the same index, and ordering a chain by block_index interleaves branches into
-- a transcript that was never said. The reliable read is to select the chain by
-- chain_id and walk prev_hash -> block_hash back from whichever row is the
-- branch tip (a row whose block_hash appears as no other row's prev_hash).
-- Every branch verifies on its own; branching is not corruption.
--
-- The one case where a sibling insert fails is two branches producing byte-
-- identical turns, which collide on the UNIQUE context_hash. The answer has
-- already been streamed by then, so the visitor watches it arrive and then sees
-- it replaced by an error — the client closes the in-flight response rather
-- than appending to it — and that turn stays out of the chain.
--
-- Indexes: the worker itself makes exactly one SELECT against this table, the
-- context_hash lookup, and that index is UNIQUE because the lookup is what
-- decides whether a client-sent history is one this worker produced. The other
-- three carry no query today; they are here for the dashboard that will read
-- this table — pulling a whole conversation by chain_id before walking it by
-- prev_hash (chain_id, block_index), filtering by day (created_at), and grouping
-- a visitor's conversations without storing who they are (ip_hash).

CREATE TABLE IF NOT EXISTS conversation_logs (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,

  -- Chain: which conversation this turn belongs to, and where in it.
  chain_id            TEXT NOT NULL,     -- 32 random bytes, hex; minted at the first turn
  block_hash          TEXT NOT NULL,     -- SHA-256 over this turn's canonical fields
  prev_hash           TEXT,              -- previous block_hash; NULL on the first turn
  block_index         INTEGER NOT NULL,  -- 0-based depth along a branch, NOT unique in a chain

  -- Continuation key: SHA-256 of the conversation INCLUDING this turn — the
  -- value the next turn's prior context hashes to. Re-deriving it from a stored
  -- row means normalizing the text fields (NFC, LF) first; D1 keeps them raw.
  context_hash        TEXT NOT NULL,

  -- The turn itself.
  user_message        TEXT NOT NULL,
  assistant_response  TEXT NOT NULL,

  -- Metadata. None of it is read by the worker and none of it is covered by the
  -- hash chain, which spans user_message and assistant_response only.
  --
  -- locale is what makes a logged turn reproducible: it names which llms-full
  -- file was in the system prompt, and the two locales feed the model different
  -- site content. That is not recoverable from the stored text — a short answer
  -- carries no reliable signal of the language it was produced under.
  locale              TEXT DEFAULT 'tr',
  ip_hash             TEXT,              -- SHA-256(ip); a grouping key for the dashboard
  model               TEXT NOT NULL,
  tokens_in           INTEGER NOT NULL,
  tokens_out          INTEGER NOT NULL,
  latency_ms          INTEGER NOT NULL,
  created_at          INTEGER NOT NULL   -- Unix epoch milliseconds (Date.now())
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_context_hash ON conversation_logs(context_hash);
CREATE INDEX IF NOT EXISTS idx_chain_block ON conversation_logs(chain_id, block_index);
CREATE INDEX IF NOT EXISTS idx_logs_created ON conversation_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_logs_ip_hash ON conversation_logs(ip_hash);
