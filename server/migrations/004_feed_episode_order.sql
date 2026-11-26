ALTER TABLE episodes ADD COLUMN estimated_publication timestamptz, ADD COLUMN feed_order integer;

UPDATE podcasts p SET etag = '', last_modified = ''
WHERE EXISTS (
    SELECT 1 FROM episodes e WHERE e.podcast_id = p.id AND e.published_at IS NULL AND NOT e.removed_from_feed
);

CREATE TABLE ambiguous_feed_guids (
    podcast_id bigint NOT NULL REFERENCES podcasts (id),
    guid_hash bytea NOT NULL,
    PRIMARY KEY (podcast_id, guid_hash)
);
