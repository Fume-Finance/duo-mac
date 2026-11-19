// duo-mac-tailnet: Tailscale built into Duo Mac, so the Mac needs no Tailscale app.
//
// It joins your tailnet as its own device (tsnet, Tailscale's library) and does what
// `tailscale serve` did for Duo Mac: https://<name>.<tailnet>.ts.net with a real certificate,
// forwarded to the helper on this Mac (127.0.0.1:8890), saying who's asking the way serve does
// (X-Forwarded-For, Tailscale-User-Login). Only devices on your tailnet can reach it.
//
// The helper (BuiltinTailnet.swift on the Mac side) starts it, reads the first line ("control <addr>"),
// then asks it for its status, for who a tailnet address is and whether its https address answers,
// with a token. It stops when the helper does (its stdin closes).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"time"

	"tailscale.com/tsnet"
)

// serve answers on ln with time limits: a client that sends its request headers slowly, or keeps an
// idle connection open, can't hold a connection forever. (No limit on a whole request: the
// WebSocket to the helper stays open as long as the phone is connected.)
func serve(ln net.Listener, h http.Handler) error {
	srv := &http.Server{
		Handler:           h,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	return srv.Serve(ln)
}

func main() {
	dir := flag.String("dir", "", "where the device's state is kept")
	hostname := flag.String("hostname", "duo-mac", "the device's name on the tailnet")
	target := flag.String("target", "http://127.0.0.1:8890", "the helper")
	flag.Parse()
	token := os.Getenv("DUO_TAILNET_TOKEN")
	if *dir == "" || token == "" {
		log.Fatal("needs -dir and DUO_TAILNET_TOKEN")
	}
	to, err := url.Parse(*target)
	if err != nil {
		log.Fatal(err)
	}

	s := &tsnet.Server{Dir: *dir, Hostname: *hostname, Logf: func(string, ...any) {}, UserLogf: log.Printf}
	if err := s.Start(); err != nil {
		log.Fatal(err)
	}
	lc, err := s.LocalClient()
	if err != nil {
		log.Fatal(err)
	}

	// The helper's questions.
	var serving atomic.Bool // the https address is up: signed in, with HTTPS certificates on
	mux := http.NewServeMux()
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		st, err := lc.Status(ctx)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		json.NewEncoder(w).Encode(st)
	})
	mux.HandleFunc("/whois", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()
		who, err := lc.WhoIs(ctx, r.URL.Query().Get("ip"))
		if err != nil {
			http.Error(w, err.Error(), 404)
			return
		}
		json.NewEncoder(w).Encode(who)
	})
	// Whether the https address is up and answers, tried over the tailnet the way an iPhone opens
	// it (the Mac itself may not be on the tailnet, so the helper can't try it directly).
	mux.HandleFunc("/probe", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		up := serving.Load()
		json.NewEncoder(w).Encode(map[string]bool{"serving": up, "reachable": up && probe(ctx, s)})
	})
	ctl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	go serve(ctl, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			http.Error(w, "no", 403)
			return
		}
		mux.ServeHTTP(w, r)
	}))
	out := bufio.NewWriter(os.Stdout)
	fmt.Fprintf(out, "control %s\n", ctl.Addr())
	out.Flush()

	// Serving: once signed in (the helper shows the sign-in link from /status).
	go func() {
		for {
			st, err := lc.StatusWithoutPeers(context.Background())
			if err == nil && st.BackendState == "Running" {
				break
			}
			time.Sleep(time.Second)
		}
		var ln net.Listener
		for {
			// Needs HTTPS certificates on the tailnet (the same switch `tailscale serve` needed).
			if ln, err = s.ListenTLS("tcp", ":443"); err == nil {
				break
			}
			log.Printf("listen: %v", err)
			time.Sleep(10 * time.Second)
		}
		proxy := &httputil.ReverseProxy{
			// Rewrite runs after the client's hop-by-hop headers are gone (a Director ran before): a
			// client can't strip the headers set here by naming them in a Connection header.
			Rewrite: func(r *httputil.ProxyRequest) {
				r.SetURL(to)
				r.Out.Host = r.In.Host // the address the page was opened at, as `tailscale serve` passes it on
				// Who's asking, as `tailscale serve` says it (the helper trusts these only from this Mac).
				r.SetXForwarded()
				r.Out.Header.Set("X-Forwarded-Proto", "https")
				r.Out.Header.Del("Tailscale-User-Login")
				r.Out.Header.Del("Tailscale-User-Name")
				// Only the helper's own local-network entrance says this; never someone on the tailnet.
				r.Out.Header.Del("X-Duo-Local")
				ctx, cancel := context.WithTimeout(r.In.Context(), 3*time.Second)
				defer cancel()
				if who, err := lc.WhoIs(ctx, r.In.RemoteAddr); err == nil && who.UserProfile != nil {
					r.Out.Header.Set("Tailscale-User-Login", who.UserProfile.LoginName)
					r.Out.Header.Set("Tailscale-User-Name", strings.ToValidUTF8(who.UserProfile.DisplayName, ""))
				}
			},
			FlushInterval: -1,
		}
		serving.Store(true)
		log.Printf("serving https on the tailnet → %s", to)
		log.Print(serve(ln, proxy))
		serving.Store(false)
	}()

	// The helper quit: so do we.
	io.Copy(io.Discard, os.Stdin)
	s.Close()
}

// probe opens our own https address for /healthz over the tailnet, as an iPhone does: through the
// certificate and this proxy, on to the helper.
func probe(ctx context.Context, s *tsnet.Server) bool {
	lc, err := s.LocalClient()
	if err != nil {
		return false
	}
	st, err := lc.StatusWithoutPeers(ctx)
	if err != nil || st.Self == nil || len(st.Self.TailscaleIPs) == 0 {
		return false
	}
	name := strings.TrimSuffix(st.Self.DNSName, ".")
	addr := net.JoinHostPort(st.Self.TailscaleIPs[0].String(), "443")
	tr := &http.Transport{
		// Straight to our own tailnet address; the name is what the certificate is for.
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) { return s.Dial(ctx, "tcp", addr) },
	}
	defer tr.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, "GET", "https://"+name+"/healthz", nil)
	if err != nil {
		return false
	}
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 16))
	return resp.StatusCode == http.StatusOK && string(body) == "ok"
}
