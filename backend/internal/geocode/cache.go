package geocode

import (
	"container/list"
	"sync"
	"time"
)

// lru is a small fixed-size cache with per-entry TTL. It exists so repeated
// lookups (a pin re-dropped on the same spot, a retyped query) never reach the
// provider. Keys may contain query text; the cache is memory-only and never
// logged or persisted.
type lru struct {
	mu    sync.Mutex
	max   int
	ll    *list.List
	items map[string]*list.Element
	now   func() time.Time
}

type lruEntry struct {
	key string
	val any
	exp time.Time
}

func newLRU(max int, now func() time.Time) *lru {
	if now == nil {
		now = time.Now
	}
	return &lru{max: max, ll: list.New(), items: make(map[string]*list.Element), now: now}
}

func (c *lru) get(key string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.items[key]
	if !ok {
		return nil, false
	}
	e := el.Value.(*lruEntry)
	if !c.now().Before(e.exp) {
		c.ll.Remove(el)
		delete(c.items, key)
		return nil, false
	}
	c.ll.MoveToFront(el)
	return e.val, true
}

func (c *lru) put(key string, val any, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.items[key]; ok {
		e := el.Value.(*lruEntry)
		e.val, e.exp = val, c.now().Add(ttl)
		c.ll.MoveToFront(el)
		return
	}
	c.items[key] = c.ll.PushFront(&lruEntry{key: key, val: val, exp: c.now().Add(ttl)})
	for c.ll.Len() > c.max {
		last := c.ll.Back()
		c.ll.Remove(last)
		delete(c.items, last.Value.(*lruEntry).key)
	}
}

func (c *lru) len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ll.Len()
}
