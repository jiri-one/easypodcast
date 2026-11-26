CREATE TABLE server_metadata (
    singleton bool PRIMARY KEY DEFAULT true CHECK (singleton),
    server_id uuid NOT NULL DEFAULT gen_random_uuid(),
    state_version bigint NOT NULL DEFAULT 0
);

INSERT INTO server_metadata DEFAULT VALUES;
