package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

type deviceInfo struct {
	ID         int64
	Name       string
	CreatedAt  *time.Time
	LastSeenAt *time.Time
}

func (s store) devices(ctx context.Context) ([]deviceInfo, error) {
	rows, err := s.db.Query(ctx, "SELECT id, name, created_at, last_seen_at FROM devices ORDER BY id")
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[deviceInfo])
}

func (s store) revokeDevice(ctx context.Context, id int64) (bool, error) {
	tag, err := s.db.Exec(ctx, "DELETE FROM devices WHERE id = $1", id)
	return tag.RowsAffected() != 0, err
}

func devicesCommand(ctx context.Context, s store, args []string, out io.Writer) error {
	switch {
	case len(args) == 1 && args[0] == "list":
		devices, err := s.devices(ctx)
		if err != nil {
			return databaseError("could not list devices", err)
		}
		if _, err := fmt.Fprintln(out, "ID\tDEVICE NAME\tCREATED\tLAST SEEN"); err != nil {
			return err
		}
		for _, d := range devices {
			if _, err := fmt.Fprintf(out, "%d\t%q\t%s\t%s\n", d.ID, d.Name, deviceTime(d.CreatedAt), deviceTime(d.LastSeenAt)); err != nil {
				return err
			}
		}
		return nil
	case len(args) == 2 && args[0] == "revoke":
		if args[1] == "--all" {
			if _, err := s.db.Exec(ctx, "DELETE FROM devices"); err != nil {
				return databaseError("could not revoke devices", err)
			}
			return nil
		}
		id, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil || id <= 0 {
			return errors.New("invalid device id")
		}
		revoked, err := s.revokeDevice(ctx, id)
		if err != nil {
			return databaseError("could not revoke device", err)
		}
		if !revoked {
			return errors.New("device not found")
		}
		return nil
	default:
		return errors.New("usage: easypodcast devices list | devices revoke <id|--all>")
	}
}

func deviceTime(t *time.Time) string {
	if t == nil {
		return "-"
	}
	return t.UTC().Format(timestampLayout)
}
