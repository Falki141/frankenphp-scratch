// Command healthcheck is the container health probe. The scratch image has
// neither a shell nor curl, so the probe is a small static binary.
//
// It requests HEALTHCHECK_URL and exits 0 for a 2xx or 3xx response, otherwise
// 1. Redirects are not followed: an HTTP -> HTTPS redirect means the server is
// answering, and its target may not be reachable from inside the container.
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

// Caddy's admin endpoint: independent of the site address and of the app.
const defaultURL = "http://localhost:2019/metrics"

func main() {
	url := os.Getenv("HEALTHCHECK_URL")
	if url == "" {
		url = defaultURL
	}

	client := &http.Client{
		// Shorter than the HEALTHCHECK timeout, so that the reason is logged
		Timeout: 4 * time.Second,
		// Never send the probe through HTTP_PROXY
		Transport: &http.Transport{},
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintln(os.Stderr, "unhealthy:", err)
		os.Exit(1)
	}
	resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		fmt.Fprintf(os.Stderr, "unhealthy: %s returned %s\n", url, resp.Status)
		os.Exit(1)
	}
	fmt.Println("healthy:", resp.Status)
}
