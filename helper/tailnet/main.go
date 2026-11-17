// duo-mac-tailnet: Tailscale built into Duo Mac, so the Mac needs no Tailscale app.
//
// It joins your tailnet as its own device (tsnet, Tailscale's library) and does what
// `tailscale serve` did for Duo Mac: https://<name>.<tailnet>.ts.net with a real certificate,
// forwarded to the helper on this Mac (127.0.0.1:8890), saying who's asking the way serve does
// (X-Forwarded-For, Tailscale-User-Login). Only devices on your tailnet can reach it.
//
// The helper (Tailnet.swift on the Mac side) starts it, reads the first line ("control <addr>"),
// then asks it for its status and for who a tailnet address is, with a token. It stops when the
// helper does (its stdin closes).
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
	"time"

	"tailscale.com/tsnet"
)

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
	ctl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	go http.Serve(ctl, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		proxy := httputil.NewSingleHostReverseProxy(to)
		proxy.FlushInterval = -1
		direct := proxy.Director
		proxy.Director = func(r *http.Request) {
			remote := r.RemoteAddr
			direct(r)
			host, _, _ := net.SplitHostPort(remote)
			// As `tailscale serve` says it (the helper trusts these only from this Mac).
			r.Header.Set("X-Forwarded-For", host)
			r.Header.Set("X-Forwarded-Host", r.Host)
			r.Header.Set("X-Forwarded-Proto", "https")
			r.Header.Del("Tailscale-User-Login")
			r.Header.Del("Tailscale-User-Name")
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if who, err := lc.WhoIs(ctx, remote); err == nil && who.UserProfile != nil {
				r.Header.Set("Tailscale-User-Login", who.UserProfile.LoginName)
				r.Header.Set("Tailscale-User-Name", strings.ToValidUTF8(who.UserProfile.DisplayName, ""))
			}
		}
		log.Printf("serving https on the tailnet → %s", to)
		log.Print(http.Serve(ln, proxy))
	}()

	// The helper quit: so do we.
	io.Copy(io.Discard, os.Stdin)
	s.Close()
}
