package core

import "sync"

// HandleRegistry provides thread-safe storage for Go objects
// referenced by integer handles across the FFI boundary.
type HandleRegistry struct {
	mu      sync.RWMutex
	objects map[int64]any
	seq     int64
}

func NewHandleRegistry() *HandleRegistry {
	return &HandleRegistry{
		objects: make(map[int64]any),
	}
}

func (r *HandleRegistry) Add(obj any) int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seq++
	r.objects[r.seq] = obj
	return r.seq
}

func (r *HandleRegistry) Get(handle int64) (any, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	obj, ok := r.objects[handle]
	return obj, ok
}

// Take removes the object of handle and returns it; of two calls for one
// handle, one gets the object.
func (r *HandleRegistry) Take(handle int64) (any, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	obj, ok := r.objects[handle]
	delete(r.objects, handle)
	return obj, ok
}

func (r *HandleRegistry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.objects)
}
