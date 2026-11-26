package main

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

const (
	fetchTimeout     = 60 * time.Second
	subscribeTimeout = 80 * time.Second
	maxBackoff       = 24 * time.Hour
)

type feedTarget struct {
	ID           int64
	URL          string
	ETag         string
	LastModified string
	Failures     int
	Generation   int64
}

type refresher struct {
	store     store
	client    http.Client
	userAgent string
	interval  time.Duration
	slots     chan struct{}
	large     chan struct{}
	force     chan struct{}
}

func newRefresher(s store, userAgent string, interval time.Duration) *refresher {
	return &refresher{
		store: s, client: feedHTTPClient(), userAgent: userAgent, interval: interval,
		slots: make(chan struct{}, 4), large: make(chan struct{}, 1), force: make(chan struct{}, 1),
	}
}

func (r *refresher) run(ctx context.Context) {
	ticker := time.NewTicker(min(time.Minute, max(time.Second, r.interval/10)))
	defer ticker.Stop()
	r.refreshDue(ctx, false)
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			r.refreshDue(ctx, false)
		case <-r.force:
			r.refreshDue(ctx, true)
		}
	}
}

func (r *refresher) refreshDue(ctx context.Context, force bool) {
	rows, err := r.store.db.Query(ctx, "SELECT "+feedTargetColumns+`
		FROM podcasts WHERE subscribed AND ($1 OR next_refresh_at <= now()) ORDER BY next_refresh_at, id`, force)
	if err != nil {
		if ctx.Err() == nil {
			slog.Warn("Could not list feeds for refresh")
		}
		return
	}
	targets, err := pgx.CollectRows(rows, pgx.RowToStructByPos[feedTarget])
	if err != nil {
		slog.Warn("Could not read feeds for refresh")
		return
	}
	// Keep a slot available when background hosts are slow.
	runWorkers(ctx, len(targets), cap(r.slots)-1, func(i int) {
		target := targets[i]
		if err := r.refresh(ctx, target); err != nil && ctx.Err() == nil {
			slog.Warn("Feed refresh failed", "podcast_id", target.ID, "reason", refreshProblem(err))
		}
	})
}

func runWorkers(ctx context.Context, count, limit int, work func(int)) {
	var workers sync.WaitGroup
	jobs := make(chan int)
	for range min(count, limit) {
		workers.Go(func() {
			for i := range jobs {
				if ctx.Err() != nil {
					return
				}
				work(i)
			}
		})
	}
send:
	for i := range count {
		select {
		case jobs <- i:
		case <-ctx.Done():
			break send
		}
	}
	close(jobs)
	workers.Wait()
}

func (r *refresher) refresh(ctx context.Context, target feedTarget) (resultErr error) {
	failures := min(target.Failures+1, 63)
	backoff := r.delay(failures)
	// A process crash during parsing must leave the feed on backoff.
	tag, err := r.store.db.Exec(ctx, `UPDATE podcasts SET failures = $2, next_refresh_at = $3
		WHERE id = $1 AND fetch_generation = $4`, target.ID, failures, time.Now().Add(backoff), target.Generation)
	if err != nil || tag.RowsAffected() == 0 {
		return err
	}
	defer func() {
		if ctx.Err() != nil {
			cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
			defer cancel()
			_, err := r.store.db.Exec(cleanup, `UPDATE podcasts SET failures = $2, next_refresh_at = now()
				WHERE id = $1 AND fetch_generation = $3`, target.ID, target.Failures, target.Generation)
			resultErr = errors.Join(resultErr, err)
		}
	}()
	result, err := r.fetch(ctx, target)
	if err == nil {
		err = r.store.applyRefresh(ctx, target, result, time.Now().Add(r.delay(0)))
	}
	if err == nil || ctx.Err() != nil {
		return err
	}
	_, writeErr := r.store.db.Exec(ctx, `UPDATE podcasts SET last_error = $2, failures = $3,
		next_refresh_at = $4, fetch_generation = fetch_generation + 1 WHERE id = $1 AND fetch_generation = $5`,
		target.ID, string(refreshProblem(err)), failures, time.Now().Add(backoff), target.Generation)
	return errors.Join(err, writeErr)
}

func refreshProblem(err error) feedError {
	var problem feedError
	if errors.As(err, &problem) {
		return problem
	}
	return "could not refresh feed"
}

func (r *refresher) delay(failures int) time.Duration {
	delay := r.interval
	if failures == 0 {
		return delay - delay/10 + time.Duration(rand.Int64N(int64(delay/5)+1))
	}
	for i := 0; i < failures && delay < maxBackoff; i++ {
		delay *= 2
	}
	if delay >= maxBackoff {
		return maxBackoff
	}
	return delay - delay/10 + time.Duration(rand.Int64N(int64(delay/10)+1))
}

func (r *refresher) subscribe(ctx context.Context, raw string) (podcast, bool, error) {
	u, err := feedURL(raw)
	if err != nil {
		return podcast{}, false, err
	}
	ctx, cancel := context.WithTimeout(ctx, subscribeTimeout)
	defer cancel()
	address := u.String()
	id, err := r.store.resubscribe(ctx, address)
	if err == nil {
		p, err := r.store.podcast(ctx, id)
		return p, false, err
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return podcast{}, false, err
	}
	result, err := r.fetch(ctx, feedTarget{URL: address})
	if err != nil {
		return podcast{}, false, err
	}
	id, added, err := r.store.addFeed(ctx, address, result, time.Now().Add(r.delay(0)))
	if err != nil {
		return podcast{}, false, err
	}
	p, err := r.store.podcast(ctx, id)
	return p, added, err
}
