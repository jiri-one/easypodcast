ALTER TABLE devices
    ADD COLUMN created_at timestamptz,
    ADD COLUMN last_seen_at timestamptz;

ALTER TABLE devices
    ALTER COLUMN created_at SET DEFAULT now(),
    ALTER COLUMN last_seen_at SET DEFAULT now();
