package main

import (
	"log"
	"os"
	"strings"

	"github.com/miekg/dns"
)

// Minimal authoritative DNS server for ACME DNS-01 challenge.
// Serves the entire zone to satisfy CAA + TXT lookups from Let's Encrypt.

func main() {
	zone := os.Getenv("DNS_ZONE")
	if zone == "" {
		log.Fatal("DNS_ZONE is required")
	}
	if !strings.HasSuffix(zone, ".") {
		zone += "."
	}

	nsHost := os.Getenv("NS_HOST")
	if nsHost == "" {
		log.Fatal("NS_HOST is required")
	}
	if !strings.HasSuffix(nsHost, ".") {
		nsHost += "."
	}

	dns.HandleFunc(zone, func(w dns.ResponseWriter, r *dns.Msg) {
		msg := new(dns.Msg)
		msg.SetReply(r)
		msg.Authoritative = true

		if len(r.Question) == 0 {
			_ = w.WriteMsg(msg)
			return
		}

		qname := r.Question[0].Name
		qtype := r.Question[0].Qtype
		qtypeStr := dns.TypeToString[qtype]
		from := w.RemoteAddr().String()

		log.Printf("QUERY: %s %s from %s", qtypeStr, qname, from)

		switch {
		case qtype == dns.TypeTXT && strings.HasPrefix(strings.ToLower(qname), "_acme-challenge."):
			data, err := os.ReadFile("/tmp/acme-challenge")
			if err == nil {
				token := strings.TrimSpace(string(data))
				msg.Answer = append(msg.Answer, &dns.TXT{
					Hdr: dns.RR_Header{Name: qname, Rrtype: dns.TypeTXT, Class: dns.ClassINET, Ttl: 1},
					Txt: []string{token},
				})
				log.Printf("served TXT: %s", token)
			}

		case qtype == dns.TypeCAA:
			msg.Answer = append(msg.Answer, &dns.CAA{
				Hdr:   dns.RR_Header{Name: qname, Rrtype: dns.TypeCAA, Class: dns.ClassINET, Ttl: 300},
				Flag:  0,
				Tag:   "issue",
				Value: "letsencrypt.org",
			})
			log.Printf("served CAA: %s issue letsencrypt.org", qname)

		case qtype == dns.TypeSOA:
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
		}

		_ = w.WriteMsg(msg)
	})

	server := &dns.Server{Addr: ":53", Net: "udp"}
	log.Printf("acme-dns listening on :53 (zone: %s)", zone)

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("failed: %v", err)
	}
}
