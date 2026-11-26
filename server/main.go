package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/term"
)

var version = "dev"

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, nil)))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

const usage = "usage: easypodcast serve | healthcheck | migrate | user set-password <name> [--password-stdin] | devices list | devices revoke <id> | import-opml <file> | import-pinepods --pinepods-dsn <dsn> --pinepods-user <name>"

func run(ctx context.Context, args []string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	if args[0] == "--help" || args[0] == "-h" {
		fmt.Println(usage)
		return nil
	}
	if args[0] == "healthcheck" {
		if len(args) != 1 {
			return errors.New(usage)
		}
		return healthcheck(ctx)
	}
	dsn := os.Getenv("EASYPODCAST_DATABASE_URL")
	if dsn == "" {
		return errors.New("EASYPODCAST_DATABASE_URL is required")
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return errors.New("invalid EASYPODCAST_DATABASE_URL")
	}
	defer pool.Close()
	s := store{pool}
	switch args[0] {
	case "migrate", "serve":
		if len(args) != 1 {
			return errors.New(usage)
		}
		if err := s.migrate(ctx); err != nil {
			return databaseError("database migration failed", err)
		}
		if args[0] == "serve" {
			r, err := configureRefresher(s)
			if err != nil {
				return err
			}
			return serve(ctx, s, r)
		}
		return nil
	case "user":
		if len(args) < 3 || len(args) > 4 || args[1] != "set-password" {
			return errors.New(usage)
		}
		name := args[2]
		fromStdin := len(args) == 4
		if fromStdin && name == "--password-stdin" {
			name = args[3]
		}
		if fromStdin && args[2] != "--password-stdin" && args[3] != "--password-stdin" {
			return errors.New(usage)
		}
		if name == "" || strings.HasPrefix(name, "--") {
			return errors.New(usage)
		}
		password, err := readPassword(fromStdin)
		if err != nil {
			return err
		}
		return s.setPassword(ctx, name, password)
	case "devices":
		return devicesCommand(ctx, s, args[1:], os.Stdout)
	case "import-opml":
		if len(args) != 2 {
			return errors.New(usage)
		}
		r, err := configureRefresher(s)
		if err != nil {
			return err
		}
		file, err := os.Open(args[1])
		if err != nil {
			return errors.New("could not open OPML file")
		}
		defer file.Close()
		addresses, err := parseOPML(file)
		if err != nil {
			return err
		}
		result, err := r.importOPML(ctx, addresses)
		fmt.Printf("Added %d, existing %d, failed %d\n", result.Added, result.Existing, len(result.Failed))
		if err != nil {
			return databaseError("OPML import interrupted", err)
		}
		if len(result.Failed) > 0 {
			return errors.New("some subscriptions could not be imported")
		}
		return nil
	case "import-pinepods":
		return importPinepodsCommand(ctx, s, args[1:])
	default:
		return errors.New(usage)
	}
}

func configureRefresher(s store) (*refresher, error) {
	interval := time.Hour
	if value := os.Getenv("EASYPODCAST_REFRESH_INTERVAL"); value != "" {
		var err error
		interval, err = time.ParseDuration(value)
		if err != nil || interval <= 0 {
			return nil, errors.New("EASYPODCAST_REFRESH_INTERVAL must be a positive Go duration")
		}
	}
	agent := os.Getenv("EASYPODCAST_USER_AGENT")
	if agent == "" {
		agent = "EasyPodcast/" + version + " (+https://github.com/jiri-one/easypodcast)"
	}
	return newRefresher(s, agent, interval), nil
}

func listenAddress() string {
	if address := os.Getenv("EASYPODCAST_LISTEN"); address != "" {
		return address
	}
	return ":8080"
}

func healthcheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_, service, err := net.SplitHostPort(listenAddress())
	if err != nil {
		return errors.New("invalid EASYPODCAST_LISTEN")
	}
	port, err := net.DefaultResolver.LookupPort(ctx, "tcp", service)
	if err != nil || port == 0 {
		return errors.New("invalid port in EASYPODCAST_LISTEN")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/health", port), nil)
	if err != nil {
		return err
	}
	client := http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("healthcheck request failed: %w", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthcheck returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func serve(ctx context.Context, s store, r *refresher) error {
	address := listenAddress()
	a := newAPI(s, r)
	a.logins.trustedProxies = parseTrustedProxies(os.Getenv("EASYPODCAST_TRUSTED_PROXIES"))
	server := &http.Server{
		Addr: address, Handler: a.routes(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: time.Minute,
		ErrorLog: slog.NewLogLogger(slog.Default().Handler(), slog.LevelError),
	}
	runCtx, cancel := context.WithCancel(ctx)
	refreshDone := make(chan struct{})
	go func() {
		defer close(refreshDone)
		r.run(runCtx)
	}()
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-runCtx.Done()
		shutdownCtx, stop := context.WithTimeout(context.Background(), fetchTimeout+time.Second)
		defer stop()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
		}
	}()
	slog.Info("Serving EasyPodcast", "listen", address)
	err := server.ListenAndServe()
	cancel()
	<-shutdownDone
	<-refreshDone
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func readPassword(fromStdin bool) (string, error) {
	if fromStdin {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 4096), maxRequestBytes)
		if !scanner.Scan() {
			return "", errors.New("could not read a password line from stdin")
		}
		return scanner.Text(), nil
	}
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) {
		return "", errors.New("a terminal is required unless --password-stdin is used")
	}
	fmt.Fprint(os.Stderr, "Password: ")
	first, err := term.ReadPassword(fd)
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", errors.New("could not read password")
	}
	fmt.Fprint(os.Stderr, "Repeat password: ")
	second, err := term.ReadPassword(fd)
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", errors.New("could not read password confirmation")
	}
	if string(first) != string(second) {
		return "", errors.New("passwords do not match")
	}
	return string(first), nil
}

func databaseError(message string, err error) error {
	var sqlErr interface{ SQLState() string }
	if errors.As(err, &sqlErr) {
		return fmt.Errorf("%s (SQLSTATE %s)", message, sqlErr.SQLState())
	}
	return errors.New(message)
}
