CREATE TABLE users (
    username text PRIMARY KEY,
    password_hash bytea NOT NULL,
    singleton bool NOT NULL DEFAULT true UNIQUE CHECK (singleton)
);

CREATE TABLE devices (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username text NOT NULL REFERENCES users (username),
    name text NOT NULL,
    token_hash bytea NOT NULL UNIQUE
);

CREATE TABLE podcasts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    feed_url text NOT NULL UNIQUE,
    title text NOT NULL DEFAULT '',
    author text NOT NULL DEFAULT '',
    description text NOT NULL DEFAULT '',
    image_url text,
    link text,
    subscribed bool NOT NULL DEFAULT true,
    episodes_version bigint NOT NULL DEFAULT 0,
    last_success_at timestamptz,
    last_error text,
    etag text NOT NULL DEFAULT '',
    last_modified text NOT NULL DEFAULT '',
    next_refresh_at timestamptz NOT NULL DEFAULT now(),
    failures int NOT NULL DEFAULT 0,
    fetch_generation bigint NOT NULL DEFAULT 0
);

CREATE TABLE feed_aliases (
    url text PRIMARY KEY,
    podcast_id bigint NOT NULL REFERENCES podcasts (id)
);

CREATE TABLE episodes (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    podcast_id bigint NOT NULL REFERENCES podcasts (id),
    guid text NOT NULL,
    title text NOT NULL,
    published_at timestamptz,
    duration_s bigint,
    enclosure_url text NOT NULL,
    enclosure_type text,
    enclosure_length bigint,
    link text,
    image_url text,
    removed_from_feed bool NOT NULL DEFAULT false,
    description text NOT NULL
);

CREATE UNIQUE INDEX episodes_guid ON episodes (podcast_id, guid) WHERE guid <> '';
CREATE INDEX episodes_podcast ON episodes (podcast_id);

CREATE TABLE episode_state (
    episode_id bigint PRIMARY KEY REFERENCES episodes (id),
    position_ms bigint NOT NULL CHECK (position_ms >= 0),
    status text NOT NULL CHECK (status IN ('', 'played', 'dismissed')),
    updated_at timestamptz NOT NULL
);

CREATE TABLE queue (
    singleton bool PRIMARY KEY DEFAULT true CHECK (singleton),
    episode_ids bigint[] NOT NULL,
    updated_at timestamptz NOT NULL
);
