package geocode

import (
	"context"
	"net/http"
	"testing"
)

func localSvc(t *testing.T, typ string, h func(r *http.Request) (int, []byte)) (*recorder, *Service) {
	t.Helper()
	rc, url := serve(t, h)
	svc, err := New(Settings{URL: url, Type: typ, AllowPrivate: true})
	if err != nil {
		t.Fatal(err)
	}
	return rc, svc
}

var alma = &Point{Lat: 35.50652, Lon: -94.05592}

func TestLocalFirstPhotonBboxAndLang(t *testing.T) {
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) {
		return 200, fixture(t, "photon_poi.json")
	})
	resp, err := svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{Bias: alma})
	if err != nil || len(resp.Results) == 0 {
		t.Fatalf("res=%v err=%v", resp.Results, err)
	}
	if rc.count() != 1 {
		t.Fatalf("local hit must stop after 1 request, got %d", rc.count())
	}
	q := rc.last().Query()
	if q.Get("bbox") != "-94.956,34.607,-93.156,36.407" {
		t.Errorf("bbox = %q", q.Get("bbox"))
	}
	if q.Get("lang") != "en" {
		t.Errorf("lang = %q", q.Get("lang"))
	}
	if !resp.Results[0].Local {
		t.Error("result should be flagged local")
	}
}

func TestLocalEmptyFallsBackToGlobal(t *testing.T) {
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) {
		if r.URL.Query().Get("bbox") != "" {
			return 200, fixture(t, "photon_empty.json")
		}
		return 200, fixture(t, "photon_poi.json")
	})
	resp, err := svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{Bias: alma})
	if err != nil || len(resp.Results) == 0 {
		t.Fatalf("res=%v err=%v", resp.Results, err)
	}
	if rc.count() != 2 {
		t.Fatalf("want local then global, got %d", rc.count())
	}
	if rc.last().Query().Get("bbox") != "" || rc.last().Query().Get("location_bias_scale") == "" {
		t.Errorf("fallback must be the soft-bias search: %v", rc.last().RawQuery)
	}
	if resp.Results[0].Local {
		t.Error("global result must not be flagged local")
	}
}

func TestNoBiasNoBbox(t *testing.T) {
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_poi.json") })
	if _, err := svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{}); err != nil {
		t.Fatal(err)
	}
	if rc.last().Query().Has("bbox") {
		t.Error("no bias, no bbox")
	}
}

func TestLocalCacheSeparation(t *testing.T) {
	// Local empty + global hit; repeating must serve both from cache, and a
	// different bias must not reuse them.
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) {
		if r.URL.Query().Get("bbox") != "" {
			return 200, fixture(t, "photon_empty.json")
		}
		return 200, fixture(t, "photon_poi.json")
	})
	ctx := context.Background()
	svc.SearchWith(ctx, "u", "Alma High School", SearchOptions{Bias: alma})
	r2, _ := svc.SearchWith(ctx, "u", "Alma High School", SearchOptions{Bias: alma})
	if rc.count() != 2 || !r2.Cached {
		t.Fatalf("count=%d cached=%v", rc.count(), r2.Cached)
	}
	svc.SearchWith(ctx, "u", "Alma High School", SearchOptions{Bias: &Point{10, 10}})
	if rc.count() != 4 {
		t.Fatalf("other bias must miss the cache, count=%d", rc.count())
	}
	// A different language must miss too.
	svc.SearchWith(ctx, "u", "Alma High School", SearchOptions{Bias: alma, Lang: "fr"})
	if rc.count() != 6 {
		t.Fatalf("other lang must miss the cache, count=%d", rc.count())
	}
}

func TestPhotonLangMapping(t *testing.T) {
	for in, want := range map[string]string{"de-DE": "de", "FR": "fr", "ar": "en", "ja-JP": "en", "it": "it", "en-US": "en"} {
		if got := photonLang(in); got != want {
			t.Errorf("photonLang(%q)=%q want %q", in, got, want)
		}
	}
}

func TestLangPrecedence(t *testing.T) {
	rc, url := serve(t, func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_poi.json") })
	svc, _ := New(Settings{URL: url, AllowPrivate: true, Lang: "de"})
	svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{})
	if rc.last().Query().Get("lang") != "de" {
		t.Errorf("config lang: %v", rc.last().RawQuery)
	}
	svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{Lang: "fr"})
	if rc.last().Query().Get("lang") != "fr" {
		t.Errorf("request lang: %v", rc.last().RawQuery)
	}
}

func TestNominatimLocalBounded(t *testing.T) {
	rc, svc := localSvc(t, "nominatim", func(r *http.Request) (int, []byte) {
		return 200, fixture(t, "nominatim_search.json")
	})
	if _, err := svc.SearchWith(context.Background(), "u", "Alma High School", SearchOptions{Bias: alma, Explicit: true, Lang: "ar"}); err != nil {
		t.Fatal(err)
	}
	q := rc.urls[0].Query()
	if q.Get("bounded") != "1" || q.Get("viewbox") != "-94.956,36.407,-93.156,34.607" {
		t.Errorf("viewbox=%q bounded=%q", q.Get("viewbox"), q.Get("bounded"))
	}
	if q.Get("accept-language") != "ar" {
		t.Errorf("accept-language=%q", q.Get("accept-language"))
	}
}

func TestRankByDistanceTieBreak(t *testing.T) {
	far := Result{Label: "far", Lat: 33.3, Lon: 44.4}
	near := Result{Label: "near", Lat: 35.6, Lon: -94.0}
	got := rankByDistance([]Result{far, near}, alma)
	if got[0].Label != "near" {
		t.Errorf("near must come first: %v", got)
	}
}

func TestReverseLangInKeyAndURL(t *testing.T) {
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) { return 200, fixture(t, "photon_house.json") })
	ctx := context.Background()
	svc.ReverseLang(ctx, "u", Point{1, 2}, "de-AT")
	if rc.last().Query().Get("lang") != "de" {
		t.Errorf("%v", rc.last().RawQuery)
	}
	svc.ReverseLang(ctx, "u", Point{1, 2}, "fr")
	if rc.count() != 2 {
		t.Error("lang must be part of the reverse cache key")
	}
}

func TestValidLang(t *testing.T) {
	for l, want := range map[string]bool{"en": true, "pt-BR": true, "": false, "en_US": false, "a&b": false, "-x": false, "abcdefghijklmnopq": false} {
		if ValidLang(l) != want {
			t.Errorf("ValidLang(%q)", l)
		}
	}
}

func TestLocalRetriesSplitCompound(t *testing.T) {
	rc, svc := localSvc(t, "photon", func(r *http.Request) (int, []byte) {
		if r.URL.Query().Get("q") == "Alma High school" {
			return 200, fixture(t, "photon_poi.json")
		}
		return 200, fixture(t, "photon_empty.json")
	})
	resp, err := svc.SearchWith(context.Background(), "u", "Alma Highschool", SearchOptions{Bias: alma})
	if err != nil || len(resp.Results) == 0 || !resp.Results[0].Local || rc.count() != 2 {
		t.Fatalf("res=%v err=%v calls=%d", resp.Results, err, rc.count())
	}
	if splitCompounds("Alma Highschool") != "Alma High school" {
		t.Logf("got %q", splitCompounds("Alma Highschool"))
	}
}
