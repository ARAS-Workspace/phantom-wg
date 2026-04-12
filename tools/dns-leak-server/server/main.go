package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
)

var (
	zone          string
	nsHost        string
	sharedSecret  []byte
	serverIPv4    string
	serverIPv6    string
	tokenTTL      int64 = 30
	resolverCache sync.Map // random → resolver IP
)

func main() {
	zone = requireEnv("DNS_ZONE")
	if !strings.HasSuffix(zone, ".") {
		zone += "."
	}

	nsHost = requireEnv("NS_HOST")
	if !strings.HasSuffix(nsHost, ".") {
		nsHost += "."
	}

	sharedSecret = loadSecret()
	serverIPv4 = requireEnv("SERVER_IPV4")
	serverIPv6 = os.Getenv("SERVER_IPV6")

	if v := os.Getenv("TOKEN_TTL"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			tokenTTL = n
		}
	}

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":53"
	}

	// Start DNS server
	dns.HandleFunc(zone, handleQuery)
	go func() {
		server := &dns.Server{Addr: listenAddr, Net: "udp"}
		log.Printf("dns listening on %s/udp (zone: %s)", listenAddr, zone)
		if err := server.ListenAndServe(); err != nil {
			log.Fatalf("dns failed: %v", err)
		}
	}()

	// Start HTTPS server
	cert, err := tls.LoadX509KeyPair("/run/secrets/tls_cert", "/run/secrets/tls_key")
	if err != nil {
		log.Fatalf("tls load failed: %v", err)
	}

	httpsServer := &http.Server{
		Addr:    ":443",
		Handler: http.HandlerFunc(handleHTTP),
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
		},
	}
	log.Printf("https listening on :443")
	log.Fatal(httpsServer.ListenAndServeTLS("", ""))
}

// ── DNS Handler ──────────────────────────────────────────

func handleQuery(w dns.ResponseWriter, r *dns.Msg) {
	msg := new(dns.Msg)
	msg.SetReply(r)
	msg.Authoritative = true

	if len(r.Question) == 0 {
		msg.Rcode = dns.RcodeRefused
		_ = w.WriteMsg(msg)
		return
	}

	qname := strings.ToLower(r.Question[0].Name)
	qtype := r.Question[0].Qtype

	// Zone infrastructure queries (SOA, NS, CAA)
	if qname == zone || qtype == dns.TypeSOA || qtype == dns.TypeNS || qtype == dns.TypeCAA {
		switch qtype {
		case dns.TypeSOA:
			msg.Answer = append(msg.Answer, &dns.SOA{
				Hdr:     dns.RR_Header{Name: zone, Rrtype: dns.TypeSOA, Class: dns.ClassINET, Ttl: 300},
				Ns:      nsHost,
				Mbox:    "admin." + zone,
				Serial:  1,
				Refresh: 3600,
				Retry:   600,
				Expire:  86400,
				Minttl:  1,
			})
		case dns.TypeNS:
			msg.Answer = append(msg.Answer, &dns.NS{
				Hdr: dns.RR_Header{Name: zone, Rrtype: dns.TypeNS, Class: dns.ClassINET, Ttl: 300},
				Ns:  nsHost,
			})
		case dns.TypeCAA:
			msg.Answer = append(msg.Answer, &dns.CAA{
				Hdr:   dns.RR_Header{Name: qname, Rrtype: dns.TypeCAA, Class: dns.ClassINET, Ttl: 300},
				Flag:  0,
				Tag:   "issue",
				Value: "letsencrypt.org",
			})
		}
		_ = w.WriteMsg(msg)
		return
	}

	prefix := strings.TrimSuffix(qname, zone)
	prefix = strings.TrimSuffix(prefix, ".")

	// Format: {random}-{hmac16}-{timestamp} (single subdomain level for wildcard TLS)
	parts := strings.Split(prefix, "-")
	if len(parts) != 3 {
		msg.Rcode = dns.RcodeRefused
		_ = w.WriteMsg(msg)
		return
	}

	random := parts[0]
	receivedMAC := parts[1]
	tsStr := parts[2]

	// Stateless expiry
	ts, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil || time.Now().Unix()-ts > tokenTTL || ts > time.Now().Unix() {
		msg.Rcode = dns.RcodeRefused
		_ = w.WriteMsg(msg)
		return
	}

	// HMAC covers random + timestamp
	if !verifyHMAC(random+tsStr, receivedMAC) {
		msg.Rcode = dns.RcodeRefused
		_ = w.WriteMsg(msg)
		return
	}

	// Capture resolver IP
	resolverIP, _, _ := net.SplitHostPort(w.RemoteAddr().String())
	resolverCache.Store(random, resolverIP)

	log.Printf("dns ok: random=%s resolver=%s", random, resolverIP)

	// Respond with server's own IP so browser connects back to us

	if qtype == dns.TypeA || qtype == dns.TypeANY {
		if serverIPv4 != "" {
			msg.Answer = append(msg.Answer, &dns.A{
				Hdr: dns.RR_Header{Name: qname, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 0},
				A:   net.ParseIP(serverIPv4),
			})
		}
	}

	if qtype == dns.TypeAAAA || qtype == dns.TypeANY {
		if serverIPv6 != "" {
			msg.Answer = append(msg.Answer, &dns.AAAA{
				Hdr:  dns.RR_Header{Name: qname, Rrtype: dns.TypeAAAA, Class: dns.ClassINET, Ttl: 0},
				AAAA: net.ParseIP(serverIPv6),
			})
		}
	}

	_ = w.WriteMsg(msg)
}

// ── HTTPS Handler ────────────────────────────────────────

func handleHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	// Extract random from Host header: {random}-{hmac}-{ts}.dns-leak-server.phantom.tc
	host := r.Host
	dotParts := strings.Split(host, ".")
	if len(dotParts) < 2 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	tokenParts := strings.Split(dotParts[0], "-")
	if len(tokenParts) != 3 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	random := tokenParts[0]

	val, ok := resolverCache.LoadAndDelete(random)
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"resolver_ip": val.(string),
	})
}

// ── Helpers ──────────────────────────────────────────────

func loadSecret() []byte {
	data, err := os.ReadFile("/run/secrets/shared_secret")
	if err == nil {
		return []byte(strings.TrimSpace(string(data)))
	}
	if val := os.Getenv("SHARED_SECRET"); val != "" {
		return []byte(val)
	}
	log.Fatal("shared secret not found")
	return nil
}

func verifyHMAC(payload, receivedHex string) bool {
	mac := hmac.New(sha256.New, sharedSecret)
	mac.Write([]byte(payload))
	expected := hex.EncodeToString(mac.Sum(nil))[:16]
	return hmac.Equal([]byte(expected), []byte(receivedHex))
}

func requireEnv(key string) string {
	val := os.Getenv(key)
	if val == "" {
		log.Fatalf("required: %s", key)
	}
	return val
}
