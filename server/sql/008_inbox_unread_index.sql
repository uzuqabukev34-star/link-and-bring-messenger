BEGIN;

CREATE INDEX IF NOT EXISTS inbox_events_unread_recipient_idx
  ON inbox_events (recipient_id, kind) WHERE read_at IS NULL;

COMMIT;
