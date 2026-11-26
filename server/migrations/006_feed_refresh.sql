ALTER TABLE podcasts ADD COLUMN feed_episode_order bigint[];

UPDATE podcasts SET next_refresh_at = now()
WHERE subscribed AND last_error = 'feed is too large';
