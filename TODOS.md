# TODOs

## Rendering

- **LRU-evict the ModelBaker sprite cache**
  - **What:** Add eviction (LRU or a size cap) to `ui/model_baker.gd` `_cache`.
  - **Why:** The cache is keyed by kind × variant × 24 azimuth buckets × 2 views,
    each a 192px texture. With the map/terrain catalog work, terrain *kinds* grow
    over time; at ~10 kinds × 3 variants × 24 × 2 that's ~200MB of baked textures.
  - **Context:** Not a v1 blocker — baking is lazy (`request()` only bakes angles
    actually drawn), so the working set stays small until a single map routinely
    shows many distinct kinds on screen. Revisit when profiling flags baker memory,
    or when maps commonly mix 6+ kinds. See `MAP_MODDING.md` §0.13 and the eng
    review's performance section.
  - **Depends on:** the data-driven terrain-kind catalog (`MAP_MODDING.md` §5).
