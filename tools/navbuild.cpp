// navbuild: Recast/Detour navmesh tiles from .geo files, then a sparse walkable-path graph.
//
//   navbuild tiles <geo_dir> <nav_dir> <threads>        one .nav per ADT tile (4x4 Detour tiles)
//   navbuild graph <nav_dir> <out.graph> <threads> [pois.txt]  graph over the whole map, with nodes at the
//                                                      points of interest (NAV_DEBUG=1 for island and edge stats)
//   navbuild line <nav_dir> X1 Y1 Z1 X2 Y2 Z2            the edge checks between two world points
//   navbuild heights <nav_dir> <out.hgt> <threads>      ground heights every 8 yards, all walkable layers (ground dots)
//   navbuild probe <nav_dir> <worldX> <worldY> x       straight-walk checks between polygons around one point
//
// World coordinates: X north, Y west, Z up. Recast coordinates: (x, y, z) = (Y, Z, X).

#include <Recast.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshBuilder.h>
#include <DetourNavMeshQuery.h>
#include <DetourCommon.h>

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <random>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

static const float TILE = 1600.0f / 3.0f;
static const float MID = 32.0f * TILE;
static const int SUB = 4;                    // Detour tiles per ADT tile side
static const float SUBTILE = TILE / SUB;     // 133.33 yards
static const int SUBCELLS = 266;             // Recast cells per Detour tile side
static const float CS = SUBTILE / SUBCELLS;  // ~0.501 yards
static const float CH = 0.25f;
static const float AGENT_HEIGHT = 2.0f, AGENT_CLIMB = 1.25f, AGENT_RADIUS = 0.5f, MAX_SLOPE = 52.0f;

// A_NARROW: ground in a walkway at most NARROW_DIST wide (ledges, planks, gaps between rocks), set after erosion
enum Area : unsigned char { A_NULL = 0, A_GROUND = 1, A_SWIM = 2, A_INDOOR = 3, A_NARROW = 4 };
// Recast's distance field counts 2 per cell (0.5 yd) from the walkable edge, which is already the agent radius
// in from the real edge: a walkway whose middle is at most 2 is up to 4 cells, about 3 yards of real ground.
static const int NARROW_DIST = 2, NARROW_REACH = 3;

struct Geo {
	std::vector<float> v;   // recast coords
	std::vector<int> t;
	std::vector<unsigned char> a;
	std::vector<int64_t> k;
};

static bool readGeo(const std::string& path, Geo& g) {
	FILE* f = fopen(path.c_str(), "rb");
	if (!f) return false;
	char magic[4];
	uint32_t nv, nt;
	if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "GEO1", 4) || fread(&nv, 4, 1, f) != 1 || fread(&nt, 4, 1, f) != 1) { fclose(f); return false; }
	std::vector<float> wv(nv * 3);
	g.t.resize(nt * 3); g.a.resize(nt); g.k.resize(nt);
	bool ok = fread(wv.data(), 4, wv.size(), f) == wv.size() && fread(g.t.data(), 4, g.t.size(), f) == g.t.size()
		&& fread(g.a.data(), 1, nt, f) == nt && fread(g.k.data(), 8, nt, f) == nt;
	fclose(f);
	g.v.resize(nv * 3);
	for (uint32_t i = 0; i < nv; i++) { g.v[i * 3] = wv[i * 3 + 1]; g.v[i * 3 + 1] = wv[i * 3 + 2]; g.v[i * 3 + 2] = wv[i * 3]; }
	return ok;
}

static std::string geoPath(const std::string& dir, int col, int row) { return dir + "/" + std::to_string(col) + "_" + std::to_string(row) + ".geo"; }

// Merge the 3x3 neighbourhood of an ADT tile, keeping each placed object once.
static void loadNeighbourhood(const std::string& dir, int col, int row, Geo& out) {
	std::unordered_set<int64_t> seen;
	for (int dr = -1; dr <= 1; dr++) for (int dc = -1; dc <= 1; dc++) {
		Geo g;
		if (!readGeo(geoPath(dir, col + dc, row + dr), g)) continue;
		std::unordered_set<int64_t> mine;
		int base = (int)out.v.size() / 3;
		out.v.insert(out.v.end(), g.v.begin(), g.v.end());
		size_t nt = g.a.size();
		for (size_t i = 0; i < nt; i++) {
			int64_t k = g.k[i];
			if (k >= 0) {
				if (seen.count(k)) continue;
				mine.insert(k);
			}
			out.t.push_back(g.t[i * 3] + base); out.t.push_back(g.t[i * 3 + 1] + base); out.t.push_back(g.t[i * 3 + 2] + base);
			out.a.push_back(g.a[i]); out.k.push_back(k);
		}
		seen.insert(mine.begin(), mine.end());
	}
}

// The collision surfaces of one ADT tile, for exact ground heights: the triangles of its 3x3 neighbourhood
// (each object once) that overlap the tile and are not walls, bucketed on a GEO_BUCKET-yard grid. Recast coords.
static const float GEO_BUCKET = 4.0f;
static void tileOf(float rx, float rz, int& col, int& row) { col = (int)floorf(32 - rx / TILE); row = (int)floorf(32 - rz / TILE); }

// The surface of the water a body at height h is in (the lowest water surface over h with no solid surface between:
// not a lake over the roof of a cave), or FLT_MAX.
static float waterOver(const std::vector<float>& hs, const std::vector<unsigned char>& wet, float h) {
	float water = FLT_MAX;
	for (size_t i = 0; i < hs.size(); i++) if (wet[i] && hs[i] > h) water = std::min(water, hs[i]);
	for (size_t i = 0; i < hs.size() && water < FLT_MAX; i++) if (!wet[i] && hs[i] > h + 0.3f && hs[i] < water) return FLT_MAX;
	return water;
}

struct GeoTile {
	float x0 = 0, z0 = 0;
	int nb = 0;
	std::vector<float> v;
	std::vector<int> t, start, items;
	std::vector<unsigned char> liquid; // per kept triangle: a water (or other liquid) surface
	std::vector<float> cosn;           // per kept triangle: the cosine of its slope
	std::vector<int> wt, wstart, witems; // with walls: the walls (steeper than the kept ones), bucketed the same way
	bool load(const std::string& dir, int col, int row, bool walls = false) {
		Geo g;
		loadNeighbourhood(dir, col, row, g);
		x0 = (31 - col) * TILE; z0 = (31 - row) * TILE;
		nb = (int)ceilf(TILE / GEO_BUCKET);
		start.assign(nb * nb + 1, 0);
		wstart.assign(nb * nb + 1, 0);
		if (g.a.empty()) return false;
		v = std::move(g.v);
		std::vector<std::vector<int>> bucket(nb * nb), wbucket(walls ? nb * nb : 0);
		size_t nt = g.a.size();
		for (size_t i = 0; i < nt; i++) {
			const float* a = &v[g.t[i * 3] * 3]; const float* b = &v[g.t[i * 3 + 1] * 3]; const float* c = &v[g.t[i * 3 + 2] * 3];
			float e0[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, e1[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
			float ny = e0[2] * e1[0] - e0[0] * e1[2];
			float nx = e0[1] * e1[2] - e0[2] * e1[1], nz = e0[0] * e1[1] - e0[1] * e1[0];
			float len = sqrtf(nx * nx + ny * ny + nz * nz);
			if (len < 1e-8f) continue;
			bool wall = fabsf(ny) / len < 0.2f;
			if (wall && !walls) continue;
			float mnx = std::min({ a[0], b[0], c[0] }), mxx = std::max({ a[0], b[0], c[0] });
			float mnz = std::min({ a[2], b[2], c[2] }), mxz = std::max({ a[2], b[2], c[2] });
			if (mxx < x0 || mnx > x0 + TILE || mxz < z0 || mnz > z0 + TILE) continue;
			std::vector<int>& tt = wall ? wt : t;
			int ti = (int)(tt.size() / 3);
			tt.push_back(g.t[i * 3]); tt.push_back(g.t[i * 3 + 1]); tt.push_back(g.t[i * 3 + 2]);
			if (!wall) { liquid.push_back(g.a[i] == A_SWIM); cosn.push_back(fabsf(ny) / len); }
			int bx0 = std::max(0, (int)floorf((mnx - x0) / GEO_BUCKET)), bx1 = std::min(nb - 1, (int)floorf((mxx - x0) / GEO_BUCKET));
			int bz0 = std::max(0, (int)floorf((mnz - z0) / GEO_BUCKET)), bz1 = std::min(nb - 1, (int)floorf((mxz - z0) / GEO_BUCKET));
			for (int bz = bz0; bz <= bz1; bz++) for (int bx = bx0; bx <= bx1; bx++) (wall ? wbucket : bucket)[bz * nb + bx].push_back(ti);
		}
		for (int i = 0; i < nb * nb; i++) { start[i + 1] = start[i] + (int)bucket[i].size(); items.insert(items.end(), bucket[i].begin(), bucket[i].end()); }
		for (int i = 0; walls && i < nb * nb; i++) { wstart[i + 1] = wstart[i] + (int)wbucket[i].size(); witems.insert(witems.end(), wbucket[i].begin(), wbucket[i].end()); }
		return true;
	}
	// whether the segment from (x0, y, z0) to (x1, y, z1) goes through a wall (load with walls)
	bool wallHit(float ax, float az, float bx, float bz, float y) const {
		float d[3] = { bx - ax, 0, bz - az };
		int cx0 = std::max(0, (int)floorf((std::min(ax, bx) - x0) / GEO_BUCKET)), cx1 = std::min(nb - 1, (int)floorf((std::max(ax, bx) - x0) / GEO_BUCKET));
		int cz0 = std::max(0, (int)floorf((std::min(az, bz) - z0) / GEO_BUCKET)), cz1 = std::min(nb - 1, (int)floorf((std::max(az, bz) - z0) / GEO_BUCKET));
		for (int cz = cz0; cz <= cz1; cz++) for (int cx = cx0; cx <= cx1; cx++) {
			for (int k = wstart[cz * nb + cx], e = wstart[cz * nb + cx + 1]; k < e; k++) {
				int ti = witems[k];
				const float* a = &v[wt[ti * 3] * 3]; const float* b = &v[wt[ti * 3 + 1] * 3]; const float* c = &v[wt[ti * 3 + 2] * 3];
				// Moller-Trumbore: p + s d, s in [0, 1]
				float e1[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, e2[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
				float pv[3] = { d[1] * e2[2] - d[2] * e2[1], d[2] * e2[0] - d[0] * e2[2], d[0] * e2[1] - d[1] * e2[0] };
				float det = e1[0] * pv[0] + e1[1] * pv[1] + e1[2] * pv[2];
				if (fabsf(det) < 1e-9f) continue;
				float inv = 1 / det, tv[3] = { ax - a[0], y - a[1], az - a[2] };
				float u = (tv[0] * pv[0] + tv[1] * pv[1] + tv[2] * pv[2]) * inv;
				if (u < 0 || u > 1) continue;
				float qv[3] = { tv[1] * e1[2] - tv[2] * e1[1], tv[2] * e1[0] - tv[0] * e1[2], tv[0] * e1[1] - tv[1] * e1[0] };
				float w = (d[0] * qv[0] + d[1] * qv[1] + d[2] * qv[2]) * inv;
				if (w < 0 || u + w > 1) continue;
				float sp = (e2[0] * qv[0] + e2[1] * qv[1] + e2[2] * qv[2]) * inv;
				if (sp >= 0 && sp <= 1) return true;
			}
		}
		return false;
	}
	// heights of the surfaces over recast (x, z); wet: whether each is a liquid's; cs: the cosine of each one's slope
	void heightsAt(float x, float z, std::vector<float>& out, std::vector<unsigned char>* wet = nullptr, std::vector<float>* cs = nullptr) const {
		out.clear();
		if (wet) wet->clear();
		if (cs) cs->clear();
		int bx = (int)floorf((x - x0) / GEO_BUCKET), bz = (int)floorf((z - z0) / GEO_BUCKET);
		if (bx < 0 || bz < 0 || bx >= nb || bz >= nb) return;
		for (int k = start[bz * nb + bx], e = start[bz * nb + bx + 1]; k < e; k++) {
			int ti = items[k];
			const float* a = &v[t[ti * 3] * 3]; const float* b = &v[t[ti * 3 + 1] * 3]; const float* c = &v[t[ti * 3 + 2] * 3];
			float v0x = b[0] - a[0], v0z = b[2] - a[2], v1x = c[0] - a[0], v1z = c[2] - a[2], px = x - a[0], pz = z - a[2];
			float den = v0x * v1z - v1x * v0z;
			if (fabsf(den) < 1e-9f) continue;
			float u = (px * v1z - v1x * pz) / den, w = (v0x * pz - px * v0z) / den;
			if (u < -1e-4f || w < -1e-4f || u + w > 1 + 1e-4f) continue;
			out.push_back(a[1] + u * (b[1] - a[1]) + w * (c[1] - a[1]));
			if (wet) wet->push_back(liquid[ti]);
			if (cs) cs->push_back(cosn[ti]);
		}
	}
};

static const float Builder_WALK_STEP = 2.0f; // Builder::WALK_STEP (Builder comes later)

// Per-thread cache of loaded GeoTiles (a few at a time: city tiles are big).
struct GeoCache {
	std::string dir;
	bool walls = false; // load the walls too (walkTo)
	std::vector<std::pair<std::pair<int, int>, std::unique_ptr<GeoTile>>> tiles;
	std::vector<float> hs;
	const GeoTile* at(float rx, float rz) {
		int col, row; tileOf(rx, rz, col, row);
		for (size_t i = 0; i < tiles.size(); i++) if (tiles[i].first == std::make_pair(col, row)) {
			if (i) std::swap(tiles[i], tiles[0]);
			return tiles[0].second.get();
		}
		auto g = std::make_unique<GeoTile>();
		g->load(dir, col, row, walls);
		tiles.insert(tiles.begin(), std::make_pair(std::make_pair(col, row), std::move(g)));
		if (tiles.size() > 4) tiles.pop_back();
		return tiles[0].second.get();
	}
	// the surface nearest height h within [h - below, h + above] (the higher one of two as near), or NAN
	float near(float rx, float rz, float h, float below, float above) {
		at(rx, rz)->heightsAt(rx, rz, hs);
		float best = NAN;
		for (float z : hs) if (z >= h - below && z <= h + above && (best != best || fabsf(z - h) < fabsf(best - h) - 1e-3f || (fabsf(fabsf(z - h) - fabsf(best - h)) <= 1e-3f && z > best))) best = z;
		return best;
	}
	std::vector<unsigned char> wet;
	// Ground going on from height h within CRACK yards ahead of (x, z) in direction (dx, dz) (a unit vector): the
	// far side of a crack between two floor pieces or bridge planks, which a body steps over. -FLT_MAX if none.
	float acrossCrack(float x, float z, float h, float dx, float dz, float below) {
		static const float CRACK = 0.75f;
		float best = -FLT_MAX;
		for (float d = 0.25f; d <= CRACK + 1e-3f && best == -FLT_MAX; d += 0.25f) {
			at(x + dx * d, z + dz * d)->heightsAt(x + dx * d, z + dz * d, hs);
			for (float v : hs) if (v <= h + AGENT_CLIMB && v >= h - below) best = std::max(best, v);
		}
		return best;
	}
	// walking on from height h in direction (dx, dz): where the feet land at (rx, rz): the highest ground at most
	// CLIMB above h (stairs, kerbs, a rock), else falling to the highest below (not over a crack); swimming on the
	// water over it where that is over SWIM_DEPTH deep; h itself over a hole
	float step(float rx, float rz, float h, float dx, float dz) {
		static const float SWIM_DEPTH = 1.5f;
		at(rx, rz)->heightsAt(rx, rz, hs, &wet);
		float ground = -FLT_MAX, water = FLT_MAX;
		for (size_t i = 0; i < hs.size(); i++) if (!wet[i] && hs[i] <= h + AGENT_CLIMB) ground = std::max(ground, hs[i]);
		water = waterOver(hs, wet, ground); // a swimmer floats up
		if (water < FLT_MAX && water > ground + SWIM_DEPTH) return water;
		if (ground < h - Builder_WALK_STEP) {
			float best = acrossCrack(rx, rz, h, dx, dz, Builder_WALK_STEP);
			if (best > -FLT_MAX) return best;
		}
		return ground == -FLT_MAX ? h : ground;
	}
	// How far walkable ground going on from height h at (x, z) reaches in direction (dx, dz) (a unit axis), up to
	// maxLen: eighth-yard steps up or down at most CLIMB (a stair, a kerb) onto ground no steeper than 55 degrees
	// (or a bump in it) or water, over cracks under half a yard. The end is halfway past the last step.
	std::vector<float> ecs;
	float walkEdge(float x, float z, float h, float dx, float dz, float maxLen) {
		static const float SUB = 0.125f, CRACK = 0.5f;
		static const float COS_MAX = cosf(55.0f * (float)M_PI / 180), RISE_MAX = SUB * tanf(55.0f * (float)M_PI / 180) + 0.02f;
		float cur = h, last = 0;
		for (float d = SUB; d <= maxLen + 1e-4f; d += SUB) {
			at(x + dx * d, z + dz * d)->heightsAt(x + dx * d, z + dz * d, hs, &wet, &ecs);
			float best = -FLT_MAX, bcos = 1;
			for (size_t i = 0; i < hs.size(); i++)
				if (hs[i] <= cur + AGENT_CLIMB && hs[i] >= cur - AGENT_CLIMB && hs[i] > best) { best = hs[i]; bcos = wet[i] ? 1 : ecs[i]; }
			if (best == -FLT_MAX) {
				if (d - last > CRACK) return last + SUB / 2;
				continue;
			}
			if (bcos < COS_MAX && fabsf(best - cur) > RISE_MAX * (d - last) / SUB) return last + SUB / 2;
			cur = best;
			last = d;
		}
		return maxLen;
	}
	// The ground a player slides on from height h at (x, z) to (tx, tz): half-yard steps on the non-water surface
	// nearest the last height within a 78-degree slope (walls are not surfaces), over cracks under half a yard;
	// the height at (tx, tz), or NAN where it breaks off.
	float slideTo(float x, float z, float h, float tx, float tz) {
		static const float SUB = 0.5f, CRACK = 0.5f, SLOPE = 4.7f;
		float dx = tx - x, dz = tz - z, len = sqrtf(dx * dx + dz * dz);
		int n = std::max(1, (int)ceilf(len / SUB));
		float cur = h, gap = 0;
		for (int k = 1; k <= n; k++) {
			float px = x + dx * k / n, pz = z + dz * k / n, step = len / n;
			at(px, pz)->heightsAt(px, pz, hs, &wet);
			float best = NAN;
			for (size_t i = 0; i < hs.size(); i++)
				if (!wet[i] && fabsf(hs[i] - cur) <= SLOPE * (step + gap) && (best != best || fabsf(hs[i] - cur) < fabsf(best - cur))) best = hs[i];
			if (best != best) {
				gap += step;
				if (gap > CRACK || k == n) return NAN;
				continue;
			}
			cur = best;
			gap = 0;
		}
		return cur;
	}
	// whether a player has room to stand on height h at (x, z): no surface (but water) from just over the feet to
	// CLEAR above them (not under the low end of a ramp, a stair or a beam)
	bool headroom(float x, float z, float h) {
		static const float CLEAR = 1.8f;
		at(x, z)->heightsAt(x, z, hs, &wet);
		for (size_t i = 0; i < hs.size(); i++) if (!wet[i] && hs[i] > h + 0.3f && hs[i] < h + CLEAR) return false;
		return true;
	}
	// whether water over (x, z) is more than depth above height h (a swimmer would be at its surface)
	bool underWater(float x, float z, float h, float depth) {
		at(x, z)->heightsAt(x, z, hs, &wet);
		for (size_t i = 0; i < hs.size(); i++) if (wet[i] && hs[i] > h + depth) return true;
		return false;
	}
	bool wallBetween(float ax, float az, float bx, float bz, float y) {
		int c0, r0, c1, r1;
		tileOf(ax, az, c0, r0); tileOf(bx, bz, c1, r1);
		if (at(bx, bz)->wallHit(ax, az, bx, bz, y)) return true;
		return (c0 != c1 || r0 != r1) && at(ax, az)->wallHit(ax, az, bx, bz, y);
	}
	// A player walking from (x, z) at height h towards (tx, tz), in quarter-yard steps: onto the highest ground at
	// most STEP_UP above the feet (a stair, a kerb) with room to stand, not up a slope steeper than 55 degrees, not
	// through a wall at body height, not off a drop of more than maxDrop (a careful player walks round it; a crack narrower than a body
	// is no drop), swimming at the surface of water deeper than SWIM_DEPTH. Stops before the first step that cannot
	// be taken; x, z, h are where it got to. Returns the share of the way walked; why: what stopped it (WALK_*).
	enum { WALK_DONE, WALK_HOLE, WALK_DROP, WALK_STEEP, WALK_WALL_LOW, WALK_WALL_HIGH };
	std::vector<float> wcs;
	float walkTo(float& x, float& z, float& h, float tx, float tz, float maxDrop, int* why = nullptr) {
		if (why) *why = WALK_DONE;
		static const float SUB = 0.25f, STEP_UP = AGENT_CLIMB, SWIM_DEPTH = 1.5f, BODY = 0.3f;
		static const float COS_MAX = cosf(55.0f * (float)M_PI / 180), RISE_MAX = SUB * tanf(55.0f * (float)M_PI / 180);
		float sx = x, sz = z, dx = tx - x, dz = tz - z, len = sqrtf(dx * dx + dz * dz);
		if (len < 1e-3f) return 1;
		int n = std::max(1, (int)ceilf(len / SUB));
		for (int k = 1; k <= n; k++) {
			float nx = sx + dx * k / n, nz = sz + dz * k / n;
			at(nx, nz)->heightsAt(nx, nz, hs, &wet, &wcs);
			float ground = -FLT_MAX, gcos = 1, water = FLT_MAX;
			for (size_t i = 0; i < hs.size(); i++) if (!wet[i] && hs[i] <= h + STEP_UP && hs[i] > ground) { ground = hs[i]; gcos = wcs[i]; }
			if (ground > -FLT_MAX) water = waterOver(hs, wet, ground);
			else { // deep water: the surface the swimmer is at
				float top = -FLT_MAX;
				for (size_t i = 0; i < hs.size(); i++) if (wet[i] && hs[i] <= h + STEP_UP) top = std::max(top, hs[i]);
				if (top > -FLT_MAX) water = top;
			}
			float nh;
			if (water < FLT_MAX && (ground == -FLT_MAX || water > ground + SWIM_DEPTH)) nh = water;
			else {
				if (ground < h - maxDrop) { // a crack between planks is no drop
					float best = acrossCrack(nx, nz, h, dx / len, dz / len, maxDrop);
					if (best == -FLT_MAX) { if (why) *why = ground == -FLT_MAX ? WALK_HOLE : WALK_DROP; return (float)(k - 1) / n; }
					ground = best; gcos = 1;
				}
				// up a slope too steep to walk (not a bump on rough ground, not onto a stair)
				if (ground > h + RISE_MAX && gcos < COS_MAX) { if (why) *why = WALK_STEEP; return (float)(k - 1) / n; }
				if (!headroom(nx, nz, ground)) { if (why) *why = WALK_WALL_LOW; return (float)(k - 1) / n; } // no room to stand
				nh = ground;
			}
			float ex = nx + (nx - x) / SUB * BODY, ez = nz + (nz - z) / SUB * BODY; // the body reaches ahead
			if (wallBetween(x, z, ex, ez, h + STEP_UP + 0.1f)) { if (why) *why = WALK_WALL_LOW; return (float)(k - 1) / n; }
			if (wallBetween(x, z, ex, ez, h + 1.8f)) { if (why) *why = WALK_WALL_HIGH; return (float)(k - 1) / n; }
			x = nx; z = nz; h = nh;
		}
		return 1;
	}
};

struct NavBlob { int tx, ty; std::vector<unsigned char> data; };

// Ground whose widest point within NARROW_REACH cells (following walkable connections) is at most NARROW_DIST from
// the edge becomes A_NARROW: the middle of a walkway that narrow, not just the rim of open ground. True if any.
static bool markNarrow(rcCompactHeightfield& chf) {
	const int w = chf.width, h = chf.height;
	std::vector<unsigned short> m(chf.dist, chf.dist + chf.spanCount), next(chf.spanCount);
	for (int it = 0; it < NARROW_REACH; it++) {
		for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
			const rcCompactCell& c = chf.cells[x + y * w];
			for (int i = (int)c.index, ni = (int)(c.index + c.count); i < ni; i++) {
				unsigned short v = m[i];
				for (int dir = 0; dir < 4; dir++) {
					int con = rcGetCon(chf.spans[i], dir);
					if (con == RC_NOT_CONNECTED) continue;
					int ax = x + rcGetDirOffsetX(dir), ay = y + rcGetDirOffsetY(dir);
					v = std::max(v, m[chf.cells[ax + ay * w].index + con]);
				}
				next[i] = v;
			}
		}
		m.swap(next);
	}
	bool any = false;
	for (int i = 0; i < chf.spanCount; i++) {
		if ((chf.areas[i] == A_GROUND || chf.areas[i] == A_INDOOR) && m[i] <= NARROW_DIST) { chf.areas[i] = A_NARROW; any = true; }
	}
	return any;
}

// Build one Detour tile (tx, ty in Detour tile grid) from the merged geometry.
static bool buildSubTile(const Geo& g, int tx, int ty, NavBlob& out, rcContext& ctx) {
	rcConfig cfg{};
	cfg.cs = CS; cfg.ch = CH;
	cfg.walkableSlopeAngle = MAX_SLOPE;
	cfg.walkableHeight = (int)ceilf(AGENT_HEIGHT / CH);
	cfg.walkableClimb = (int)floorf(AGENT_CLIMB / CH);
	cfg.walkableRadius = (int)ceilf(AGENT_RADIUS / CS);
	cfg.maxEdgeLen = (int)(24.0f / CS);
	cfg.maxSimplificationError = 1.3f;
	cfg.minRegionArea = 30;
	cfg.mergeRegionArea = 400;
	cfg.maxVertsPerPoly = 6;
	cfg.tileSize = SUBCELLS;
	cfg.borderSize = cfg.walkableRadius + 3;
	cfg.width = cfg.tileSize + cfg.borderSize * 2;
	cfg.height = cfg.tileSize + cfg.borderSize * 2;
	cfg.detailSampleDist = CS * 6;
	cfg.detailSampleMaxError = CH * 2;
	float bx0 = -MID + tx * SUBTILE, bz0 = -MID + ty * SUBTILE;
	cfg.bmin[0] = bx0 - cfg.borderSize * CS; cfg.bmin[2] = bz0 - cfg.borderSize * CS;
	cfg.bmax[0] = bx0 + SUBTILE + cfg.borderSize * CS; cfg.bmax[2] = bz0 + SUBTILE + cfg.borderSize * CS;

	// triangles overlapping the padded tile, with areas from slope (two-sided) and the source area
	std::vector<int> tris;
	std::vector<unsigned char> areas;
	float ymin = FLT_MAX, ymax = -FLT_MAX;
	const float cosSlope = cosf(MAX_SLOPE / 180.0f * (float)M_PI);
	size_t nt = g.a.size();
	for (size_t i = 0; i < nt; i++) {
		const float* a = &g.v[g.t[i * 3] * 3]; const float* b = &g.v[g.t[i * 3 + 1] * 3]; const float* c = &g.v[g.t[i * 3 + 2] * 3];
		float mnx = std::min({ a[0], b[0], c[0] }), mxx = std::max({ a[0], b[0], c[0] });
		float mnz = std::min({ a[2], b[2], c[2] }), mxz = std::max({ a[2], b[2], c[2] });
		if (mxx < cfg.bmin[0] || mnx > cfg.bmax[0] || mxz < cfg.bmin[2] || mnz > cfg.bmax[2]) continue;
		float e0[3] = { b[0] - a[0], b[1] - a[1], b[2] - a[2] }, e1[3] = { c[0] - a[0], c[1] - a[1], c[2] - a[2] };
		float n[3] = { e0[1] * e1[2] - e0[2] * e1[1], e0[2] * e1[0] - e0[0] * e1[2], e0[0] * e1[1] - e0[1] * e1[0] };
		float len = sqrtf(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
		if (len <= 1e-8f) continue;
		unsigned char area = g.a[i];
		if (fabsf(n[1]) / len < cosSlope) area = RC_NULL_AREA;
		tris.push_back(g.t[i * 3]); tris.push_back(g.t[i * 3 + 1]); tris.push_back(g.t[i * 3 + 2]);
		areas.push_back(area);
		ymin = std::min({ ymin, a[1], b[1], c[1] }); ymax = std::max({ ymax, a[1], b[1], c[1] });
	}
	if (areas.empty()) return false;
	cfg.bmin[1] = ymin - 2; cfg.bmax[1] = ymax + 4;

	rcHeightfield* hf = rcAllocHeightfield();
	bool ok = rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
	ok = ok && rcRasterizeTriangles(&ctx, g.v.data(), (int)g.v.size() / 3, tris.data(), areas.data(), (int)areas.size(), *hf, cfg.walkableClimb);
	if (!ok) { rcFreeHeightField(hf); return false; }
	rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
	rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
	rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);
	rcCompactHeightfield* chf = rcAllocCompactHeightfield();
	ok = rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf);
	rcFreeHeightField(hf);
	ok = ok && rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf);
	ok = ok && rcBuildDistanceField(&ctx, *chf);
	if (ok && markNarrow(*chf)) ok = rcBuildDistanceField(&ctx, *chf); // regions split where the area changes
	ok = ok && rcBuildRegions(&ctx, *chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea);
	rcContourSet* cset = rcAllocContourSet();
	ok = ok && rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset);
	rcPolyMesh* pm = rcAllocPolyMesh();
	ok = ok && cset->nconts > 0 && rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pm);
	rcPolyMeshDetail* dm = rcAllocPolyMeshDetail();
	ok = ok && pm->npolys > 0 && rcBuildPolyMeshDetail(&ctx, *pm, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *dm);
	rcFreeCompactHeightfield(chf);
	rcFreeContourSet(cset);
	if (ok) {
		for (int i = 0; i < pm->npolys; i++) pm->flags[i] = 1;
		dtNavMeshCreateParams p{};
		p.verts = pm->verts; p.vertCount = pm->nverts; p.polys = pm->polys; p.polyAreas = pm->areas; p.polyFlags = pm->flags;
		p.polyCount = pm->npolys; p.nvp = pm->nvp;
		p.detailMeshes = dm->meshes; p.detailVerts = dm->verts; p.detailVertsCount = dm->nverts;
		p.detailTris = dm->tris; p.detailTriCount = dm->ntris;
		p.walkableHeight = AGENT_HEIGHT; p.walkableRadius = AGENT_RADIUS; p.walkableClimb = AGENT_CLIMB;
		p.tileX = tx; p.tileY = ty; p.tileLayer = 0;
		rcVcopy(p.bmin, pm->bmin); rcVcopy(p.bmax, pm->bmax);
		p.cs = cfg.cs; p.ch = cfg.ch; p.buildBvTree = true;
		unsigned char* data = nullptr; int size = 0;
		if (dtCreateNavMeshData(&p, &data, &size)) {
			out.tx = tx; out.ty = ty; out.data.assign(data, data + size);
			dtFree(data);
		} else ok = false;
	}
	rcFreePolyMesh(pm);
	rcFreePolyMeshDetail(dm);
	return ok;
}

static std::vector<std::pair<int, int>> listTiles(const std::string& dir, const char* ext) {
	std::vector<std::pair<int, int>> out;
	DIR* d = opendir(dir.c_str());
	if (!d) return out;
	while (dirent* e = readdir(d)) {
		int c, r; char x[16];
		if (sscanf(e->d_name, "%d_%d.%15s", &c, &r, x) == 3 && strcmp(x, ext) == 0) out.push_back({ c, r });
	}
	closedir(d);
	std::sort(out.begin(), out.end(), [](auto& a, auto& b) { return a.second != b.second ? a.second < b.second : a.first < b.first; });
	return out;
}

static int cmdTiles(const std::string& geoDir, const std::string& navDir, int threads) {
	auto tiles = listTiles(geoDir, "geo");
	std::atomic<size_t> next{ 0 }, done{ 0 };
	std::atomic<long> polys{ 0 };
	std::mutex logm;
	auto worker = [&]() {
		rcContext ctx(false);
		for (;;) {
			size_t i = next++;
			if (i >= tiles.size()) break;
			int col = tiles[i].first, row = tiles[i].second;
			std::string outPath = navDir + "/" + std::to_string(col) + "_" + std::to_string(row) + ".nav";
			if (FILE* f = fopen(outPath.c_str(), "rb")) { fclose(f); done++; continue; }
			Geo g;
			loadNeighbourhood(geoDir, col, row, g);
			std::vector<NavBlob> blobs;
			// ADT (col, row) spans recast x = world Y in [(31-col)T - MID.., ] -> Detour tile x = (63-col)*SUB.., y = (63-row)*SUB..
			for (int sy = 0; sy < SUB; sy++) for (int sx = 0; sx < SUB; sx++) {
				NavBlob b;
				if (buildSubTile(g, (63 - col) * SUB + sx, (63 - row) * SUB + sy, b, ctx)) {
					polys += ((dtMeshHeader*)b.data.data())->polyCount;
					blobs.push_back(std::move(b));
				}
			}
			std::string tmp = outPath + ".tmp";
			FILE* f = fopen(tmp.c_str(), "wb");
			uint32_t n = (uint32_t)blobs.size();
			fwrite(&n, 4, 1, f);
			for (auto& b : blobs) {
				int32_t hdr[3] = { b.tx, b.ty, (int32_t)b.data.size() };
				fwrite(hdr, 4, 3, f);
				fwrite(b.data.data(), 1, b.data.size(), f);
			}
			fclose(f);
			rename(tmp.c_str(), outPath.c_str());
			size_t d = ++done;
			if (d % 25 == 0 || d == tiles.size()) {
				std::lock_guard<std::mutex> l(logm);
				printf("%zu/%zu tiles, %ld polys\n", d, tiles.size(), polys.load());
				fflush(stdout);
			}
		}
	};
	std::vector<std::thread> pool;
	for (int i = 0; i < threads; i++) pool.emplace_back(worker);
	for (auto& t : pool) t.join();
	return 0;
}

// ------------------------------------------------------------------------------------------ graph
static const float CELL = 64.0f;          // graph cell size, yards
static const int MAX_RAY_PATH = 512;
static const float MIN_ISLAND = 400.0f;      // smaller walkable islands (roofs, tree tops, rocks) get no nodes
static const float CLEAR = 8.0f;             // yards from walls that count as open ground when centring routes

static const float SWIM_COST = 2.5f, NARROW_COST = 2.5f; // path cost per yard; the addon's MULT matches
enum EdgeFlag : unsigned char { F_SWIM = 1, F_NARROW = 2 };
static float costOf(unsigned char fl) { return (fl & F_SWIM) ? SWIM_COST : (fl & F_NARROW) ? NARROW_COST : 1.0f; }

// poi: placed where a quest giver, quest object or town service stands (tools/pois.py), on every walkable layer
struct Node { float p[3]; dtPolyRef ref; int cx, cz; unsigned char area; bool poi = false; };
struct Edge { int a, b; unsigned char flags; };

static dtNavMesh* loadNavMesh(const std::string& navDir) {
	dtNavMesh* nav = dtAllocNavMesh();
	dtNavMeshParams np{};
	np.orig[0] = -MID; np.orig[1] = 0; np.orig[2] = -MID;
	np.tileWidth = SUBTILE; np.tileHeight = SUBTILE;
	np.maxTiles = 1 << 16; np.maxPolys = 1 << 20;
	if (dtStatusFailed(nav->init(&np))) { fprintf(stderr, "navmesh init failed\n"); return nullptr; }
	long total = 0;
	for (auto& t : listTiles(navDir, "nav")) {
		std::string path = navDir + "/" + std::to_string(t.first) + "_" + std::to_string(t.second) + ".nav";
		FILE* f = fopen(path.c_str(), "rb");
		uint32_t n = 0;
		if (fread(&n, 4, 1, f) != 1) n = 0;
		for (uint32_t i = 0; i < n; i++) {
			int32_t hdr[3];
			if (fread(hdr, 4, 3, f) != 3) break;
			unsigned char* data = (unsigned char*)dtAlloc(hdr[2], DT_ALLOC_PERM);
			if (fread(data, 1, hdr[2], f) != (size_t)hdr[2]) { dtFree(data); break; }
			if (dtStatusFailed(nav->addTile(data, hdr[2], DT_TILE_FREE_DATA, 0, nullptr))) dtFree(data);
			else total++;
		}
		fclose(f);
	}
	printf("loaded %ld navmesh tiles\n", total);
	return nav;
}

struct Builder {
	dtNavMesh* nav;
	int threads;
	dtQueryFilter filter;
	std::vector<Node> nodes;
	std::map<std::pair<int, int>, std::vector<int>> cells;
	std::vector<Edge> edges;
	std::vector<char> dead;
	std::mutex m;

	Builder() {
		filter.setIncludeFlags(0xffff);
		filter.setAreaCost(A_SWIM, SWIM_COST);
		filter.setAreaCost(A_NARROW, NARROW_COST);
	}

	// Walkable islands: every polygon gets the id of its linked component; compArea is its 2D area.
	std::unordered_map<dtPolyRef, int> comp;
	std::vector<float> compArea;

	void labelComponents() {
		const dtNavMesh* cn = nav;
		std::vector<dtPolyRef> stack;
		for (int ti = 0; ti < cn->getMaxTiles(); ti++) {
			const dtMeshTile* tile = cn->getTile(ti);
			if (!tile || !tile->header) continue;
			dtPolyRef base = cn->getPolyRefBase(tile);
			for (int pi = 0; pi < tile->header->polyCount; pi++) {
				dtPolyRef start = base | (dtPolyRef)pi;
				if (tile->polys[pi].getType() != DT_POLYTYPE_GROUND || comp.count(start)) continue;
				int id = (int)compArea.size();
				float area = 0;
				comp[start] = id;
				stack.push_back(start);
				while (!stack.empty()) {
					dtPolyRef r = stack.back(); stack.pop_back();
					const dtMeshTile* t; const dtPoly* p;
					cn->getTileAndPolyByRefUnsafe(r, &t, &p);
					for (int k = 2; k < p->vertCount; k++)
						area += fabsf(dtTriArea2D(&t->verts[p->verts[0] * 3], &t->verts[p->verts[k - 1] * 3], &t->verts[p->verts[k] * 3]));
					for (unsigned int l = p->firstLink; l != DT_NULL_LINK; l = t->links[l].next) {
						dtPolyRef nr = t->links[l].ref;
						if (nr && comp.emplace(nr, id).second) stack.push_back(nr);
					}
				}
				compArea.push_back(area);
			}
		}
		int big = 0;
		for (float a : compArea) if (a >= MIN_ISLAND) big++;
		printf("navmesh polys: %zu in %zu islands, %d of at least %.0f sq yd\n", comp.size(), compArea.size(), big, MIN_ISLAND);
		if (getenv("NAV_DEBUG")) {
			std::vector<std::array<float, 4>> bb(compArea.size(), { 1e9f, 1e9f, -1e9f, -1e9f });
			for (auto& kv : comp) {
				const dtMeshTile* t; const dtPoly* p;
				cn->getTileAndPolyByRefUnsafe(kv.first, &t, &p);
				auto& b = bb[kv.second];
				for (int k = 0; k < p->vertCount; k++) {
					const float* v = &t->verts[p->verts[k] * 3];
					b[0] = std::min(b[0], v[2]); b[1] = std::min(b[1], v[0]); b[2] = std::max(b[2], v[2]); b[3] = std::max(b[3], v[0]);
				}
			}
			std::vector<int> order(compArea.size());
			for (size_t i = 0; i < order.size(); i++) order[i] = (int)i;
			std::sort(order.begin(), order.end(), [&](int x, int y) { return compArea[x] > compArea[y]; });
			for (int i = 0; i < 12 && i < (int)order.size(); i++) {
				auto& b = bb[order[i]];
				printf("  island %d: %.0f sq yd, world X %.0f..%.0f Y %.0f..%.0f\n", order[i], compArea[order[i]], b[0], b[2], b[1], b[3]);
			}
		}
	}

	int compOf(dtPolyRef r) { auto it = comp.find(r); return it == comp.end() ? -1 : it->second; }

	// Points from closestPointOnPoly sit on polygon edges, where Detour's raycast and height queries misbehave:
	// move them a little toward the polygon's centre.
	void interior(dtNavMeshQuery* q, dtPolyRef ref, float* p) {
		const dtMeshTile* t; const dtPoly* poly;
		if (dtStatusFailed(nav->getTileAndPolyByRef(ref, &t, &poly))) return;
		float c[3] = { 0, 0, 0 };
		for (int k = 0; k < poly->vertCount; k++) dtVadd(c, c, &t->verts[poly->verts[k] * 3]);
		dtVscale(c, c, 1.0f / poly->vertCount);
		float d = dtVdist2D(p, c);
		if (d < 1e-3f) return;
		float m[3], out[3]; bool over;
		dtVlerp(m, p, c, std::min(0.3f / d, 0.5f));
		if (dtStatusSucceed(q->closestPointOnPoly(ref, m, out, &over))) dtVcopy(p, out);
	}

	// Shortest-path corners hug walls and rocks. Walk a point away from the nearest wall until it sits midway
	// between walls, or CLEAR yards from any, so routes run down the middle of tunnels, doorways and passes.
	void center(dtNavMeshQuery* q, dtPolyRef& ref, float* p) {
		if (getenv("NAV_NOCENTER")) return;
		float hd, hp[3], hn[3];
		if (dtStatusFailed(q->findDistanceToWall(ref, p, CLEAR, &filter, &hd, hp, hn))) return;
		float step = 2.0f, moved = 0;
		for (int it = 0; it < 24 && hd < CLEAR && step > 0.1f && moved < CLEAR; it++) {
			float target[3] = { p[0] + hn[0] * step, p[1], p[2] + hn[2] * step };
			float res[3], h, nd, np[3], nn[3];
			dtPolyRef visited[16]; int nv = 0;
			if (dtStatusFailed(q->moveAlongSurface(ref, p, target, &filter, res, visited, &nv, 16)) || nv == 0) break;
			dtPolyRef nref = visited[nv - 1];
			if (dtStatusSucceed(q->getPolyHeight(nref, res, &h))) res[1] = h;
			if (dtStatusFailed(q->findDistanceToWall(nref, res, CLEAR, &filter, &nd, np, nn)) || nd <= hd + 0.02f) { step *= 0.5f; continue; }
			moved += dtVdist2D(p, res);
			dtVcopy(p, res); ref = nref; hd = nd; dtVcopy(hn, nn);
		}
	}

	unsigned char polyArea(dtPolyRef ref) {
		const dtMeshTile* tile; const dtPoly* poly;
		if (dtStatusFailed(nav->getTileAndPolyByRef(ref, &tile, &poly))) return 0;
		return poly->getArea();
	}

	static unsigned char areaFlag(unsigned char area) { return area == A_SWIM ? F_SWIM : area == A_NARROW ? F_NARROW : 0; }
	unsigned char pathFlags(const dtPolyRef* path, int n) {
		unsigned char fl = 0;
		for (int i = 0; i < n; i++) fl |= areaFlag(polyArea(path[i]));
		return fl;
	}

	// Shortest navmesh walk from a to b: length, largest sideways deviation from the straight line,
	// swim/narrow flags and the corner points. False when b is unreachable within the search budget.
	bool walk(dtNavMeshQuery* q, dtPolyRef aRef, const float* a, dtPolyRef bRef, const float* b,
		float& len, float& dev, unsigned char& flags, std::vector<std::array<float, 3>>* corners = nullptr,
		std::vector<dtPolyRef>* cornerRefs = nullptr) {
		static const int MAX_POLYS = 2048, MAX_CORNERS = 256;
		dtPolyRef path[MAX_POLYS];
		int np = 0;
		if (dtStatusFailed(q->findPath(aRef, bRef, a, b, &filter, path, &np, MAX_POLYS)) || np == 0 || path[np - 1] != bRef) return false;
		float sp[MAX_CORNERS * 3]; unsigned char spf[MAX_CORNERS]; dtPolyRef spr[MAX_CORNERS]; int ns = 0;
		if (dtStatusFailed(q->findStraightPath(a, b, path, np, sp, spf, spr, &ns, MAX_CORNERS, 0)) || ns < 2) return false;
		len = 0; dev = 0;
		float dx = b[0] - a[0], dz = b[2] - a[2], d2 = dx * dx + dz * dz;
		for (int k = 0; k < ns; k++) {
			if (k) len += dtVdist(&sp[(k - 1) * 3], &sp[k * 3]);
			float px = sp[k * 3] - a[0], pz = sp[k * 3 + 2] - a[2];
			float t = d2 > 0 ? std::max(0.0f, std::min(1.0f, (px * dx + pz * dz) / d2)) : 0;
			float ex = px - dx * t, ez = pz - dz * t;
			dev = std::max(dev, sqrtf(ex * ex + ez * ez));
			if (corners) { corners->push_back({ sp[k * 3], sp[k * 3 + 1], sp[k * 3 + 2] }); cornerRefs->push_back(spr[k]); }
		}
		flags = pathFlags(path, np);
		return true;
	}

	// Straight walk check from a to b on the navmesh. flags: F_SWIM / F_NARROW for the polygons crossed.
	// Points on polygon edges make Detour's raycast stop at t=0, so start a hair toward b, on its polygon.
	bool straight(dtNavMeshQuery* q, dtPolyRef aRef, const float* a, const float* b, dtPolyRef bRef, unsigned char& flags) {
		float d = dtVdist2D(a, b);
		if (d < 0.05f) { flags = 0; return true; }
		float s[3], sp[3];
		dtVlerp(s, a, b, std::min(0.1f / d, 0.5f));
		const float ext[3] = { 0.3f, 2.0f, 0.3f };
		dtPolyRef sref = 0;
		if (dtStatusFailed(q->findNearestPoly(s, ext, &filter, &sref, sp)) || !sref) { sref = aRef; dtVcopy(sp, a); }
		dtPolyRef path[MAX_RAY_PATH];
		dtRaycastHit hit{};
		hit.path = path; hit.maxPath = MAX_RAY_PATH;
		if (dtStatusFailed(q->raycast(sref, sp, b, &filter, 0, &hit))) return false;
		if (hit.t != FLT_MAX || hit.pathCount == 0) return false;
		dtPolyRef last = path[hit.pathCount - 1];
		if (last != bRef) {
			float cp[3]; bool over;
			if (dtStatusFailed(q->closestPointOnPoly(last, b, cp, &over)) || dtVdist(cp, b) > 1.5f) return false;
		}
		flags = pathFlags(path, hit.pathCount);
		return true;
	}

	// Straight, or bending at most a yard around something thin (a post); trees and rocks get routed around,
	// since the ground dots are drawn exactly along these lines.
	bool nearlyStraight(dtNavMeshQuery* q, const Node& a, const Node& b, unsigned char& flags) {
		if (straight(q, a.ref, a.p, b.p, b.ref, flags) || straight(q, b.ref, b.p, a.p, a.ref, flags)) return true;
		// both ways round: Detour's shortest path can differ by direction, and an edge is walked both ways
		float len, dev, d = dtVdist(a.p, b.p);
		if (walk(q, a.ref, a.p, b.ref, b.p, len, dev, flags) && len <= d * 1.02f + 0.5f && dev <= 1.0f) return true;
		return walk(q, b.ref, b.p, a.ref, a.p, len, dev, flags) && len <= d * 1.02f + 0.5f && dev <= 1.0f;
	}

	// One node per walkable patch of every CELL x CELL square; points a short walk apart share a node.
	void sampleCells() {
		int minx = INT32_MAX, maxx = INT32_MIN, minz = INT32_MAX, maxz = INT32_MIN;
		for (int i = 0; i < nav->getMaxTiles(); i++) {
			const dtMeshTile* t = ((const dtNavMesh*)nav)->getTile(i);
			if (!t || !t->header) continue;
			minx = std::min(minx, (int)floorf(t->header->bmin[0] / CELL)); maxx = std::max(maxx, (int)floorf(t->header->bmax[0] / CELL));
			minz = std::min(minz, (int)floorf(t->header->bmin[2] / CELL)); maxz = std::max(maxz, (int)floorf(t->header->bmax[2] / CELL));
		}
		std::atomic<int> nextRow{ minz };
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			std::vector<dtPolyRef> refs(8192);
			struct Cand { float d; float p[3]; dtPolyRef ref; };
			for (;;) {
				int cz = nextRow++;
				if (cz > maxz) break;
				std::vector<Node> local;
				for (int cx = minx; cx <= maxx; cx++) {
					float c[3] = { (cx + 0.5f) * CELL, 0, (cz + 0.5f) * CELL };
					float ext[3] = { CELL / 2, 5000, CELL / 2 };
					int n = 0;
					q->queryPolygons(c, ext, &filter, refs.data(), &n, (int)refs.size());
					std::vector<Cand> cands;
					for (int i = 0; i < n; i++) {
						Cand cd; bool over;
						int ci = compOf(refs[i]);
						if (ci < 0 || compArea[ci] < MIN_ISLAND) continue;
						if (dtStatusFailed(q->closestPointOnPoly(refs[i], c, cd.p, &over))) continue;
						interior(q, refs[i], cd.p);
						center(q, refs[i], cd.p);
						float dx = cd.p[0] - c[0], dz = cd.p[2] - c[2];
						if (fabsf(dx) > CELL / 2 || fabsf(dz) > CELL / 2) continue;
						cd.d = dx * dx + dz * dz; cd.ref = refs[i];
						cands.push_back(cd);
					}
					std::sort(cands.begin(), cands.end(), [](const Cand& x, const Cand& y) { return x.d < y.d; });
					std::vector<Node> reps;
					for (auto& cd : cands) {
						bool joined = false;
						for (auto& r : reps) {
							if (fabsf(r.p[1] - cd.p[1]) > 12 || compOf(r.ref) != compOf(cd.ref)) continue;
							unsigned char fl;
							if (straight(q, r.ref, r.p, cd.p, cd.ref, fl)) { joined = true; break; }
							float len, dev;
							if (walk(q, r.ref, r.p, cd.ref, cd.p, len, dev, fl) && len <= dtVdist(r.p, cd.p) * 1.4f + 10) { joined = true; break; }
						}
						if (joined) continue;
						Node nd;
						dtVcopy(nd.p, cd.p); nd.ref = cd.ref; nd.cx = cx; nd.cz = cz; nd.area = polyArea(cd.ref);
						reps.push_back(nd);
					}
					local.insert(local.end(), reps.begin(), reps.end());
				}
				std::lock_guard<std::mutex> l(m);
				nodes.insert(nodes.end(), local.begin(), local.end());
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		// rows in order, whichever thread did them: the same graph every build
		std::stable_sort(nodes.begin(), nodes.end(), [](const Node& a, const Node& b) { return a.cz < b.cz; });
		for (size_t i = 0; i < nodes.size(); i++) cells[{ nodes[i].cx, nodes[i].cz }].push_back((int)i);
		std::map<size_t, int> hist;
		for (auto& kv : cells) hist[kv.second.size()]++;
		printf("cell nodes: %zu in %zu cells; nodes per cell:", nodes.size(), cells.size());
		for (auto& kv : hist) if (kv.first <= 8) printf(" %zu:%d", kv.first, kv.second);
		printf("\n");
	}

	std::atomic<int> debugLeft{ getenv("NAV_DEBUG") ? 40 : 0 };
	void debugPair(dtNavMeshQuery* q, const Node& a, const Node& b) {
		float len = -1, dev = -1; unsigned char fl;
		bool w = walk(q, a.ref, a.p, b.ref, b.p, len, dev, fl);
		dtPolyRef path[MAX_RAY_PATH]; dtRaycastHit hit{}; hit.path = path; hit.maxPath = MAX_RAY_PATH;
		q->raycast(a.ref, a.p, b.p, &filter, 0, &hit);
		float hp[3]; dtVlerp(hp, a.p, b.p, std::min(hit.t, 1.0f));
		float tx = (hp[0] + MID) / SUBTILE, tz = (hp[2] + MID) / SUBTILE;
		std::lock_guard<std::mutex> l(m);
		printf("fail d %.1f dy %.1f walk %d len %.1f dev %.1f | ray t %.3f n %d hit at tile frac (%.3f %.3f) normal (%.2f %.2f)\n", dtVdist2D(a.p, b.p), b.p[1] - a.p[1], w, len, dev,
			hit.t, hit.pathCount, tx - floorf(tx), tz - floorf(tz), hit.hitNormal[0], hit.hitNormal[2]);
	}

	// Flags a node's own ground gives every edge leaving it: a swimmer's edges swim.
	static unsigned char nodeFlag(const Node& n) { return areaFlag(n.area); }

	void connect() {
		// the last offset, the node's own cell, only for POI nodes (cell nodes in one cell were merged already)
		static const int OFF[17][2] = { {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1},
			{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2},{0,0} };
		size_t nCell = nodes.size();
		std::atomic<size_t> next{ 0 };
		std::vector<Edge> found;
		std::vector<std::pair<int, int>> missing; // neighbouring pairs that need a route around obstacles
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			std::vector<Edge> le;
			std::vector<std::pair<int, int>> lm;
			for (;;) {
				size_t i = next++;
				if (i >= nCell) break;
				const Node& a = nodes[i];
				for (int o = 0; o < 17; o++) {
					auto it = cells.find({ a.cx + OFF[o][0], a.cz + OFF[o][1] });
					if (it == cells.end()) continue;
					for (int j : it->second) {
						if (j <= (int)i) continue; // each pair once
						const Node& b = nodes[j];
						if (o == 16 && !a.poi && !b.poi) continue;
						if (fabsf(a.p[1] - b.p[1]) > 60 || compOf(a.ref) != compOf(b.ref)) continue;
						unsigned char fl;
						bool near = o < 8 || o == 16;
						if (nearlyStraight(q, a, b, fl)) {
							// a line through water or a narrow walkway that neither end is in: the navmesh path
							// (which pays for those) may know a better way, over a bridge or round a ledge
							if (fl & ~(nodeFlag(a) | nodeFlag(b))) { if (near) lm.push_back({ (int)i, j }); }
							else le.push_back({ (int)i, j, fl });
						} else {
							if (near) lm.push_back({ (int)i, j });
							if (debugLeft > 0 && --debugLeft >= 0) debugPair(q, a, b);
						}
					}
				}
			}
			std::lock_guard<std::mutex> l(m);
			found.insert(found.end(), le.begin(), le.end());
			missing.insert(missing.end(), lm.begin(), lm.end());
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		std::sort(found.begin(), found.end(), [](const Edge& x, const Edge& y) { return x.a != y.a ? x.a < y.a : x.b < y.b; });
		std::sort(missing.begin(), missing.end());
		edges = found;
		printf("direct edges: %zu, pairs to route around obstacles: %zu\n", edges.size(), missing.size());
		repair(missing, 1.2f, 8.0f, 0, false);
	}

	// Long straight runs. Edges reach two cells at most, so a straight run across open land or down a valley
	// zigzags over the cell nodes. The navmesh's shortest paths between cell nodes LONG_MIN to LONG_MAX yards
	// apart show where real routes run straight; one is added (its legs as edges, its corners as nodes) when
	// the graph has nothing within LONG_SPAN of it, counting LEG_COST yards per leg as the add-on's search does.
	static constexpr float LONG_MIN = 150, LONG_MAX = 600, LONG_SPAN = 1.03f, LEG_COST = 10;
	static const int LONG_PAIRS = 16; // per cell node, in as many directions
	void longRuns() {
		std::mt19937 rng(1);
		std::uniform_real_distribution<float> u01(0, 1);
		std::vector<std::pair<int, int>> pairs;
		for (auto& kv : cells) for (int i : kv.second) {
			const Node& a = nodes[i];
			if (a.poi || dead[i]) continue;
			for (int k = 0; k < LONG_PAIRS; k++) {
				float ang = 6.2831853f * (k + u01(rng)) / LONG_PAIRS, d = LONG_MIN + u01(rng) * (LONG_MAX - LONG_MIN);
				float tx = a.p[0] + cosf(ang) * d, tz = a.p[2] + sinf(ang) * d;
				auto it = cells.find({ (int)floorf(tx / CELL), (int)floorf(tz / CELL) });
				if (it == cells.end()) continue;
				int best = -1; float bd = FLT_MAX;
				for (int j : it->second) {
					const Node& b = nodes[j];
					if (b.poi || dead[j] || fabsf(a.p[1] - b.p[1]) > 150 || compOf(a.ref) != compOf(b.ref)) continue;
					float dx = b.p[0] - tx, dz = b.p[2] - tz;
					if (dx * dx + dz * dz < bd) { bd = dx * dx + dz * dz; best = j; }
				}
				if (best >= 0) pairs.push_back({ i, best });
			}
		}
		printf("long runs: %zu pairs\n", pairs.size());
		size_t before = edges.size();
		repair(pairs, LONG_SPAN, 0, LEG_COST, true);
		printf("long runs: %zu edges added\n", edges.size() - before);
	}

	// Follows the navmesh path of each pair and adds it, its corners as nodes, unless the graph already has a
	// way within stretch x its cost + slack (pairs of neighbouring cells without a straight walk: obstacles to
	// route around; long runs). legCost: yards each leg costs on top of its length in that test. strict: a route
	// with a leg that is no straight walk once its corners are snapped to nodes is left out (else the leg is
	// kept: the navmesh path is walkable, only not checked as a straight line).
	void repair(const std::vector<std::pair<int, int>>& pairs, float stretch, float slack, float legCost, bool strict) {
		dead.resize(nodes.size(), 0);
		std::atomic<size_t> next{ 0 };
		// fl: flags per segment; cost: length weighted by costOf, like the addon's search
		struct Route { int a, b; float cost; std::vector<std::array<float, 3>> pts; std::vector<dtPolyRef> refs; std::vector<unsigned char> fl; };
		std::vector<Route> routes;
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 65535);
			std::vector<Route> lr;
			for (;;) {
				size_t i = next++;
				if (i >= pairs.size()) break;
				const Node& a = nodes[pairs[i].first];
				const Node& b = nodes[pairs[i].second];
				Route r; r.a = pairs[i].first; r.b = pairs[i].second;
				float len, dev; unsigned char fl;
				if (!walk(q, a.ref, a.p, b.ref, b.p, len, dev, fl, &r.pts, &r.refs)) continue;
				if (len > dtVdist(a.p, b.p) * 2.5f + 20) continue;
				for (size_t k = 1; k + 1 < r.pts.size(); k++) {
					Node prev, cur, nextN;
					dtVcopy(prev.p, r.pts[k - 1].data()); prev.ref = k == 1 ? a.ref : r.refs[k - 1];
					dtVcopy(cur.p, r.pts[k].data()); cur.ref = r.refs[k];
					dtVcopy(nextN.p, r.pts[k + 1].data()); nextN.ref = k + 2 == r.pts.size() ? b.ref : r.refs[k + 1];
					if (!cur.ref || !prev.ref || !nextN.ref) continue;
					interior(q, cur.ref, cur.p); // corners sit exactly on the wall, where "away" has no direction
					center(q, cur.ref, cur.p);
					unsigned char f1, f2;
					if (nearlyStraight(q, prev, cur, f1) && nearlyStraight(q, cur, nextN, f2)) {
						r.pts[k] = { cur.p[0], cur.p[1], cur.p[2] };
						r.refs[k] = cur.ref;
					}
				}
				size_t n = r.pts.size();
				r.fl.assign(n - 1, fl);
				r.cost = 0;
				for (size_t k = 0; k + 1 < n; k++) {
					Node u, v;
					dtVcopy(u.p, r.pts[k].data()); u.ref = k == 0 ? a.ref : r.refs[k];
					dtVcopy(v.p, r.pts[k + 1].data()); v.ref = k + 2 == n ? b.ref : r.refs[k + 1];
					unsigned char f;
					if (u.ref && v.ref && nearlyStraight(q, u, v, f)) r.fl[k] = f;
					r.cost += dtVdist(u.p, v.p) * costOf(r.fl[k]) + legCost;
				}
				lr.push_back(std::move(r));
			}
			std::lock_guard<std::mutex> l(m);
			for (auto& r : lr) routes.push_back(std::move(r));
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();

		// Cheapest routes first; a route is only added when the graph has no path within stretch of its cost
		// already (a greedy spanner), and its corners reuse any node within SNAP yards that still sees the route's
		// corners on both sides (a corner snapped blindly turns a bridge into a line beside it).
		std::sort(routes.begin(), routes.end(), [](const Route& x, const Route& y) {
			return x.cost != y.cost ? x.cost < y.cost : x.a != y.a ? x.a < y.a : x.b < y.b;
		});
		const float SNAP = 6.0f;
		std::vector<std::vector<std::pair<int, float>>> adj(nodes.size());
		auto link = [&](int a, int b, unsigned char fl) {
			edges.push_back({ a, b, fl });
			float d = dtVdist(nodes[a].p, nodes[b].p) * costOf(fl) + legCost;
			adj[a].push_back({ b, d }); adj[b].push_back({ a, d });
		};
		for (auto& e : edges) {
			if (dead[e.a] || dead[e.b]) continue;
			float d = dtVdist(nodes[e.a].p, nodes[e.b].p) * costOf(e.flags) + legCost;
			adj[e.a].push_back({ e.b, d }); adj[e.b].push_back({ e.a, d });
		}
		std::map<std::tuple<int, int, int>, std::vector<int>> grid;
		auto key = [&](const float* p) { return std::make_tuple((int)floorf(p[0] / SNAP), (int)floorf(p[1] / SNAP), (int)floorf(p[2] / SNAP)); };
		for (size_t i = 0; i < nodes.size(); i++) grid[key(nodes[i].p)].push_back((int)i);
		auto snapTo = [&](const std::array<float, 3>& p, std::vector<int>& out) {
			out.clear();
			auto k = key(p.data());
			for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) {
				auto it = grid.find({ std::get<0>(k) + dx, std::get<1>(k) + dy, std::get<2>(k) + dz });
				if (it == grid.end()) continue;
				for (int id : it->second) if (dtVdistSqr(nodes[id].p, p.data()) < SNAP * SNAP) out.push_back(id);
			}
			std::sort(out.begin(), out.end(), [&](int x, int y) { return dtVdistSqr(nodes[x].p, p.data()) < dtVdistSqr(nodes[y].p, p.data()); });
		};
		auto newNode = [&](const std::array<float, 3>& p, dtPolyRef ref) {
			Node nd; nd.p[0] = p[0]; nd.p[1] = p[1]; nd.p[2] = p[2]; nd.ref = ref;
			nd.cx = (int)floorf(p[0] / CELL); nd.cz = (int)floorf(p[2] / CELL); nd.area = polyArea(ref);
			int id = (int)nodes.size();
			nodes.push_back(nd);
			adj.emplace_back();
			grid[key(p.data())].push_back(id);
			return id;
		};
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(nav, 8192);
		size_t before = nodes.size(), used = 0, unsnapped = 0, unchecked = 0;
		std::vector<int> near;
		std::vector<int> orphans;
		for (auto& r : routes) {
			if (within(adj, r.a, r.b, r.cost * stretch + slack)) continue;
			size_t n = r.pts.size(), first = nodes.size();
			std::vector<int> ids(n);
			ids[0] = r.a; ids[n - 1] = r.b;
			for (size_t k = 1; k + 1 < n; k++) {
				dtPolyRef ref = r.refs[k] ? r.refs[k] : nodes[ids[k - 1]].ref;
				Node exactNext;
				dtVcopy(exactNext.p, r.pts[k + 1].data());
				exactNext.ref = k + 2 == n ? nodes[r.b].ref : (r.refs[k + 1] ? r.refs[k + 1] : ref);
				int id = -1;
				snapTo(r.pts[k], near);
				for (int c : near) {
					unsigned char f;
					bool fromPrev = c == ids[k - 1] || nearlyStraight(q, nodes[ids[k - 1]], nodes[c], f);
					if (fromPrev && nearlyStraight(q, nodes[c], exactNext, f)) { id = c; break; }
				}
				if (id < 0) { id = newNode(r.pts[k], ref); if (!near.empty()) unsnapped++; }
				ids[k] = id;
			}
			std::vector<unsigned char> fs(n, 0);
			bool ok = true;
			for (size_t k = 1; k < n; k++) {
				if (ids[k] == ids[k - 1]) continue;
				if (!nearlyStraight(q, nodes[ids[k - 1]], nodes[ids[k]], fs[k])) { fs[k] = r.fl[k - 1]; unchecked++; ok = false; }
			}
			if (!ok && strict) { // its new corners stay unused, and no later route snaps to them
				for (size_t id = first; id < nodes.size(); id++) {
					auto& cellIds = grid[key(nodes[id].p)];
					cellIds.erase(std::remove(cellIds.begin(), cellIds.end(), (int)id), cellIds.end());
					orphans.push_back((int)id);
				}
				continue;
			}
			used++;
			for (size_t k = 1; k < n; k++) if (ids[k] != ids[k - 1]) link(ids[k - 1], ids[k], fs[k]);
		}
		dtFreeNavMeshQuery(q);
		printf("routes added: %zu of %zu; corners kept off a nearby node that could not see the route: %zu; "
			"segments without a straight walk: %zu\n", used, routes.size(), unsnapped, unchecked);
		printf("routed pairs: %zu, corner nodes added: %zu\n", routes.size(), nodes.size() - before - orphans.size());
		dead.resize(nodes.size(), 0);
		for (int id : orphans) dead[id] = 1;
	}

	// Nodes where a player can stand to talk to a quest giver or town service, or use a quest object (tools/pois.py:
	// "worldX worldY [worldZ]" per line): the nearest point within INTERACT yards of every walkable piece on every
	// layer that is not water. Bankers and auctioneers stand behind counters, on ground too small for nodes or cut
	// off from the hall in front, so the hall in front counts, not only the ground under them. Without these nodes a
	// route ends at the nearest node in plan view, which can be the beach under the pier the NPC stands on.
	void addPois(const std::string& path) {
		// a spot with a height (from tools/pois.py) gets nodes within INTERACT of it in 3D, else on the level nearest
		// it if one is within POI_HEIGHT; one without, on every level
		static const float INTERACT = 5.0f, POI_LAYER = 3.0f, POI_REUSE = 2.0f, POI_HEIGHT = 5.0f;
		FILE* f = fopen(path.c_str(), "r");
		if (!f) { fprintf(stderr, "cannot read %s\n", path.c_str()); return; }
		std::vector<std::array<float, 3>> pts;
		char line[128];
		while (fgets(line, sizeof line, f)) {
			float X, Y, Z;
			int n = sscanf(line, "%f %f %f", &X, &Y, &Z);
			if (n >= 2) pts.push_back({ X, Y, n == 3 ? Z : NAN });
		}
		fclose(f);
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(nav, 4096);
		size_t added = 0, reused = 0, none = 0, onLevel = 0, inReach = 0;
		for (auto& w : pts) {
			float c[3] = { w[1], 0, w[0] }, ext[3] = { INTERACT, 5000, INTERACT };
			dtPolyRef refs[256]; int n = 0;
			q->queryPolygons(c, ext, &filter, refs, &n, 256);
			struct Spot { float d; float p[3]; dtPolyRef ref; int comp; };
			std::vector<Spot> spots;
			bool known = !std::isnan(w[2]);
			for (int i = 0; i < n; i++) {
				if (polyArea(refs[i]) == A_SWIM) continue;
				int ci = compOf(refs[i]);
				if (ci < 0 || compArea[ci] < MIN_ISLAND) continue;
				Spot s; bool over;
				float at[3] = { c[0], known ? w[2] : 0, c[2] };
				if (dtStatusFailed(q->closestPointOnPoly(refs[i], at, s.p, &over))) continue;
				s.d = dtVdist2D(s.p, c); s.ref = refs[i]; s.comp = ci;
				if (s.d <= INTERACT) spots.push_back(s);
			}
			if (known && !spots.empty()) {
				auto far3 = [&](const Spot& s) { return s.d * s.d + (s.p[1] - w[2]) * (s.p[1] - w[2]) > INTERACT * INTERACT; };
				bool any = false;
				for (const Spot& s : spots) any = any || !far3(s);
				if (any) { // where a player can reach it from (in front of a counter)
					spots.erase(std::remove_if(spots.begin(), spots.end(), far3), spots.end());
					for (Spot& s : spots) s.d = sqrtf(s.d * s.d + (s.p[1] - w[2]) * (s.p[1] - w[2]));
					inReach++;
				} else {
					const Spot* best = &spots[0];
					for (const Spot& s : spots) if (fabsf(s.p[1] - w[2]) < fabsf(best->p[1] - w[2])) best = &s;
					if (fabsf(best->p[1] - w[2]) <= POI_HEIGHT) {
						float h = best->p[1];
						spots.erase(std::remove_if(spots.begin(), spots.end(), [&](const Spot& s) { return fabsf(s.p[1] - h) > POI_LAYER; }), spots.end());
						onLevel++;
					}
				}
			}
			std::sort(spots.begin(), spots.end(), [](const Spot& a, const Spot& b) { return a.comp != b.comp ? a.comp < b.comp : a.p[1] < b.p[1]; });
			for (size_t i = 0; i < spots.size();) { // per walkable piece and layer, the spot nearest the POI
				size_t best = i, j = i;
				for (; j < spots.size() && spots[j].comp == spots[i].comp && spots[j].p[1] - spots[i].p[1] <= POI_LAYER; j++) if (spots[j].d < spots[best].d) best = j;
				Spot s = spots[best];
				interior(q, s.ref, s.p);
				int cx = (int)floorf(s.p[0] / CELL), cz = (int)floorf(s.p[2] / CELL), found = -1;
				for (int dx = -1; dx <= 1 && found < 0; dx++) for (int dz = -1; dz <= 1 && found < 0; dz++) {
					auto it = cells.find({ cx + dx, cz + dz });
					if (it == cells.end()) continue;
					for (int id : it->second) if (dtVdist(nodes[id].p, s.p) < POI_REUSE) { found = id; break; }
				}
				if (found >= 0) { nodes[found].poi = true; reused++; }
				else {
					Node nd;
					dtVcopy(nd.p, s.p); nd.ref = s.ref; nd.cx = cx; nd.cz = cz; nd.area = polyArea(s.ref); nd.poi = true;
					cells[{ cx, cz }].push_back((int)nodes.size());
					nodes.push_back(nd);
					added++;
				}
				i = j;
			}
			if (spots.empty()) none++;
		}
		dtFreeNavMeshQuery(q);
		printf("points of interest: %zu (%zu with ground within reach of their height, %zu on the level of their height), nodes added %zu, existing nodes used %zu, no walkable ground near %zu\n",
			pts.size(), inReach, onLevel, added, reused, none);
	}

	// Is there a way from s to t over adj (neighbour, cost) costing at most limit?
	std::vector<float> wdist;
	std::vector<int> wtouched;
	bool within(const std::vector<std::vector<std::pair<int, float>>>& adj, int s, int t, float limit) {
		wdist.resize(adj.size(), FLT_MAX);
		std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>, std::greater<>> pq;
		wdist[s] = 0; wtouched.push_back(s); pq.push({ 0.0f, s });
		bool found = false;
		while (!pq.empty()) {
			auto [d, u] = pq.top(); pq.pop();
			if (d > wdist[u]) continue;
			if (u == t) { found = true; break; }
			for (auto& [v, w] : adj[u]) {
				float nd = d + w;
				if (nd <= limit && nd < wdist[v]) { if (wdist[v] == FLT_MAX) wtouched.push_back(v); wdist[v] = nd; pq.push({ nd, v }); }
			}
		}
		for (int x : wtouched) wdist[x] = FLT_MAX;
		wtouched.clear();
		return found;
	}

	// Walking a line as a player would, independent of the raycasts that check edges: from a, follow the ground
	// the line is on (the layer within WALK_STEP of the last height: the deck, not the river under it), a yard at
	// a time. Skimming a rock or a tree is fine (edges may bend up to a yard around something thin), so ground on
	// the line's level within WALK_GRAZE yards counts. False where that ground is missing for more than WALK_GAP
	// yards, or the line ends off b's level: it runs off a bridge, a pier or a ledge (drop: other ground under or
	// over it there) or over a hole. at: where the ground was lost, at the line's height.
	static constexpr float WALK_STEP = 2.0f, WALK_GAP = 3.0f, WALK_END = 3.0f, WALK_GRAZE = 1.2f;
	// ground nearest height h within r yards of p (2D); any: whether any ground at all is within 0.3 yards
	float groundNear(dtNavMeshQuery* q, const float* p, float h, float r, bool* any) {
		float ext[3] = { r + 0.1f, 60, r + 0.1f }, best = FLT_MAX;
		dtPolyRef refs[128]; int n = 0;
		q->queryPolygons(p, ext, &filter, refs, &n, 128);
		for (int i = 0; i < n; i++) {
			float cp[3]; bool over;
			if (dtStatusFailed(q->closestPointOnPoly(refs[i], p, cp, &over))) continue;
			float d = dtVdist2D(cp, p);
			if (any && d <= 0.3f) *any = true;
			if (d <= r && fabsf(cp[1] - h) < fabsf(best - h)) best = cp[1];
		}
		return best;
	}
	bool walksLevelFrom(dtNavMeshQuery* q, const float* a, const float* e, float* at, bool& drop) {
		float dx = e[0] - a[0], dz = e[2] - a[2], len = sqrtf(dx * dx + dz * dz), h = a[1], gap = 0;
		bool otherLevel = false;
		int n = std::max(1, (int)ceilf(len));
		for (int k = 1; k <= n; k++) {
			float t = (float)k / n, p[3] = { a[0] + dx * t, h, a[2] + dz * t };
			float best = groundNear(q, p, h, 0.3f, nullptr);
			if (fabsf(best - h) <= WALK_STEP + gap * 1.3f) { h = best; gap = 0; otherLevel = false; continue; }
			bool any = false;
			float graze = groundNear(q, p, h, WALK_GRAZE, &any);
			if (fabsf(graze - h) <= WALK_STEP + gap * 1.3f) { h = graze; gap = 0; otherLevel = false; continue; } // skims something
			otherLevel = otherLevel || any;
			if ((gap += len / n) > WALK_GAP) { dtVcopy(at, p); at[1] = h; drop = otherLevel; return false; }
		}
		if (fabsf(h - e[1]) > WALK_END) { dtVcopy(at, e); at[1] = h; drop = true; return false; }
		return true;
	}
	bool walksLevel(dtNavMeshQuery* q, const float* a, const float* b, float* at, bool& drop) {
		return walksLevelFrom(q, a, b, at, drop) && walksLevelFrom(q, b, a, at, drop);
	}

	// Edges a player following the ground could not walk (walksLevel): left out where the graph has another way
	// within OFF_STRETCH of them; else replaced by the navmesh path between their ends when every leg of it is a
	// straight walk and walks level; else kept (the navmesh links the ends, and there is no other way).
	void dropOffLevel() {
		static constexpr float OFF_STRETCH = 1.3f, OFF_SLACK = 10.0f;
		std::vector<char> bad(edges.size(), 0);
		std::atomic<size_t> next{ 0 };
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			for (;;) {
				size_t i = next++;
				if (i >= edges.size()) break;
				const Edge& e = edges[i];
				float at[3]; bool drop = false;
				if (!dead[e.a] && !dead[e.b] && !walksLevel(q, nodes[e.a].p, nodes[e.b].p, at, drop)) bad[i] = 1;
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		std::vector<std::vector<std::pair<int, float>>> adj(nodes.size());
		auto cost = [&](const Edge& e) { return dtVdist(nodes[e.a].p, nodes[e.b].p) * costOf(e.flags); };
		auto add = [&](const Edge& e) { float d = cost(e); adj[e.a].push_back({ e.b, d }); adj[e.b].push_back({ e.a, d }); };
		std::vector<size_t> order;
		for (size_t i = 0; i < edges.size(); i++) {
			if (dead[edges[i].a] || dead[edges[i].b]) continue;
			if (bad[i]) order.push_back(i); else add(edges[i]);
		}
		std::sort(order.begin(), order.end(), [&](size_t x, size_t y) { return cost(edges[x]) < cost(edges[y]); });
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(nav, 65535);
		size_t dropped = 0, replaced = 0, kept = 0;
		std::vector<Edge> extra;
		for (size_t i : order) {
			const Edge e = edges[i];
			if (within(adj, e.a, e.b, cost(e) * OFF_STRETCH + OFF_SLACK)) { dropped++; continue; }
			const Node& a = nodes[e.a]; const Node& b = nodes[e.b];
			float len, dev; unsigned char fl;
			std::vector<std::array<float, 3>> pts; std::vector<dtPolyRef> refs;
			std::vector<Node> chain;
			bool ok = walk(q, a.ref, a.p, b.ref, b.p, len, dev, fl, &pts, &refs) && pts.size() > 2;
			if (ok) {
				chain.push_back(a);
				for (size_t k = 1; k + 1 < pts.size(); k++) {
					Node c; dtVcopy(c.p, pts[k].data()); c.ref = refs[k];
					if (!c.ref) { ok = false; break; }
					interior(q, c.ref, c.p); // corners sit exactly on the wall
					c.cx = (int)floorf(c.p[0] / CELL); c.cz = (int)floorf(c.p[2] / CELL); c.area = polyArea(c.ref);
					chain.push_back(c);
				}
				chain.push_back(b);
			}
			std::vector<unsigned char> fs(chain.size(), 0);
			for (size_t k = 1; ok && k < chain.size(); k++) {
				float at[3]; bool drop = false;
				ok = nearlyStraight(q, chain[k - 1], chain[k], fs[k]) && walksLevel(q, chain[k - 1].p, chain[k].p, at, drop);
			}
			if (!ok) { kept++; bad[i] = 0; add(e); continue; }
			replaced++;
			int prev = e.a;
			for (size_t k = 1; k < chain.size(); k++) {
				int id = k + 1 == chain.size() ? e.b : (int)nodes.size();
				if (id != e.b) { nodes.push_back(chain[k]); adj.emplace_back(); }
				Edge ne = { prev, id, fs[k] };
				extra.push_back(ne);
				add(ne);
				prev = id;
			}
		}
		dtFreeNavMeshQuery(q);
		std::vector<Edge> keep;
		for (size_t i = 0; i < edges.size(); i++) if (!bad[i]) keep.push_back(edges[i]);
		keep.insert(keep.end(), extra.begin(), extra.end());
		edges = keep;
		dead.resize(nodes.size(), 0);
		printf("edges that do not walk level: %zu; left out (another way within %.0f%%): %zu, replaced by the navmesh path: %zu, "
			"kept (no other way): %zu\n", order.size(), (OFF_STRETCH - 1) * 100, dropped, replaced, kept);
	}

	// Shortcuts: corners of different routes that see each other often have no edge between them, and a route
	// from one to the other zigzags over a third node. Node pairs up to SHORT_R yards apart whose way over the
	// graph is more than SHORT_SPAN times as long as a direct edge get one, if it is a straight walk that walks
	// level; shortest first, each only if the ones before have not made it a short way.
	static constexpr float SHORT_R = 40, SHORT_SPAN = 1.2f;
	void shortcuts() {
		auto cost = [&](int a, int b, unsigned char fl) { return dtVdist(nodes[a].p, nodes[b].p) * costOf(fl); };
		std::vector<std::vector<std::pair<int, float>>> adj(nodes.size());
		for (auto& e : edges) {
			if (dead[e.a] || dead[e.b]) continue;
			float c = cost(e.a, e.b, e.flags);
			adj[e.a].push_back({ e.b, c }); adj[e.b].push_back({ e.a, c });
		}
		std::map<std::pair<int, int>, std::vector<int>> grid;
		for (size_t i = 0; i < nodes.size(); i++)
			if (!dead[i]) grid[{ (int)floorf(nodes[i].p[0] / SHORT_R), (int)floorf(nodes[i].p[2] / SHORT_R) }].push_back((int)i);
		struct Cand { int a, b; float d; unsigned char fl; };
		std::vector<Cand> cands;
		std::atomic<size_t> next{ 0 };
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			std::vector<float> dist(nodes.size(), FLT_MAX);
			std::vector<int> touched;
			std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>, std::greater<>> pq;
			auto near = [&](int s, int t, float limit) { // within(), with this thread's own buffers
				dist[s] = 0; touched.push_back(s); pq.push({ 0.0f, s });
				bool found = false;
				while (!pq.empty()) {
					auto [d, u] = pq.top(); pq.pop();
					if (d > dist[u]) continue;
					if (u == t) { found = true; break; }
					for (auto& [v, w] : adj[u]) {
						float nd = d + w;
						if (nd <= limit && nd < dist[v]) { if (dist[v] == FLT_MAX) touched.push_back(v); dist[v] = nd; pq.push({ nd, v }); }
					}
				}
				while (!pq.empty()) pq.pop();
				for (int x : touched) dist[x] = FLT_MAX;
				touched.clear();
				return found;
			};
			std::vector<Cand> local;
			for (;;) {
				size_t a = next++;
				if (a >= nodes.size()) break;
				if (dead[a]) continue;
				const Node& na = nodes[a];
				int gx = (int)floorf(na.p[0] / SHORT_R), gz = (int)floorf(na.p[2] / SHORT_R);
				for (int dx = -1; dx <= 1; dx++) for (int dz = -1; dz <= 1; dz++) {
					auto it = grid.find({ gx + dx, gz + dz });
					if (it == grid.end()) continue;
					for (int b : it->second) {
						if (b <= (int)a) continue;
						const Node& nb = nodes[b];
						float d = dtVdist(na.p, nb.p);
						if (d > SHORT_R || d < 1 || near((int)a, b, d * SHORT_SPAN)) continue;
						unsigned char fl; float at[3]; bool drop = false;
						if (!nearlyStraight(q, na, nb, fl) || (fl & ~(nodeFlag(na) | nodeFlag(nb))) || !walksLevel(q, na.p, nb.p, at, drop)) continue;
						local.push_back({ (int)a, b, d, fl });
					}
				}
			}
			dtFreeNavMeshQuery(q);
			std::lock_guard<std::mutex> l(m);
			cands.insert(cands.end(), local.begin(), local.end());
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		std::sort(cands.begin(), cands.end(), [](const Cand& x, const Cand& y) { return x.d != y.d ? x.d < y.d : x.a != y.a ? x.a < y.a : x.b < y.b; });
		size_t added = 0;
		for (auto& c : cands) {
			float w = cost(c.a, c.b, c.fl);
			if (within(adj, c.a, c.b, w * SHORT_SPAN)) continue;
			edges.push_back({ c.a, c.b, c.fl });
			adj[c.a].push_back({ c.b, w }); adj[c.b].push_back({ c.a, w });
			added++;
		}
		printf("shortcuts: %zu candidates, %zu added\n", cands.size(), added);
	}

	// Every edge must still be a (nearly) straight walk; reports the ones that are not.
	void verify() {
		std::atomic<size_t> next{ 0 }, bad{ 0 };
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			for (;;) {
				size_t i = next++;
				if (i >= edges.size()) break;
				const Edge& e = edges[i];
				unsigned char fl;
				if (dead[e.a] || dead[e.b] || nearlyStraight(q, nodes[e.a], nodes[e.b], fl)) continue;
				if (bad++ < 10) {
					std::lock_guard<std::mutex> l(m);
					const float* a = nodes[e.a].p; const float* b = nodes[e.b].p;
					printf("  edge without a straight walk: world (%.1f %.1f %.1f) - (%.1f %.1f %.1f)\n", a[2], a[0], a[1], b[2], b[0], b[1]);
				}
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		printf("edges without a straight walk: %zu of %zu\n", bad.load(), edges.size());
	}

	// Route corners with two neighbours that can see each other are dropped, joining the neighbours directly.
	void simplify() {
		std::vector<std::map<int, unsigned char>> adj(nodes.size());
		for (auto& e : edges) if (e.a != e.b) { adj[e.a][e.b] = e.flags; adj[e.b][e.a] = e.flags; }
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(nav, 4096);
		size_t removed = 0;
		for (bool changed = true; changed;) {
			changed = false;
			for (size_t v = 0; v < nodes.size(); v++) {
				if (adj[v].size() != 2) continue;
				int a = adj[v].begin()->first, b = std::next(adj[v].begin())->first;
				unsigned char fl, own = adj[v][a] | adj[v][b];
				if (!nearlyStraight(q, nodes[a], nodes[b], fl) || (fl & ~own)) continue; // no shortcut through water or a ledge
				fl |= own;
				adj[a].erase((int)v); adj[b].erase((int)v); adj[v].clear();
				adj[a][b] = fl; adj[b][a] = fl;
				dead[v] = 1;
				removed++; changed = true;
			}
		}
		dtFreeNavMeshQuery(q);
		edges.clear();
		for (size_t a = 0; a < adj.size(); a++) for (auto& kv : adj[a]) if ((int)a < kv.first) edges.push_back({ (int)a, kv.first, kv.second });
		printf("simplified: %zu route corners dropped\n", removed);
	}

	// Ground heights for the addon's ground dots: every HS yards on a grid aligned with the addon's 64-yard
	// lookup cells (HereBeDragons coords + 17100), all walkable layers at each point (bridges, caves, floors).
	// HGT1 file: cell count, then per cell: cx, cy (int32), 64 layer counts (uint8), the heights (float32).

	void heights(const std::string& path) {
		static const float HS = 8.0f, OFF = 17100.0f, MERGE = 1.5f;
		static const int PER = 8, MAX_LAYERS = 4;
		int minx = INT32_MAX, maxx = INT32_MIN, minz = INT32_MAX, maxz = INT32_MIN;
		for (int i = 0; i < nav->getMaxTiles(); i++) {
			const dtMeshTile* t = ((const dtNavMesh*)nav)->getTile(i);
			if (!t || !t->header) continue;
			minx = std::min(minx, (int)floorf((t->header->bmin[0] + OFF) / CELL)); maxx = std::max(maxx, (int)floorf((t->header->bmax[0] + OFF) / CELL));
			minz = std::min(minz, (int)floorf((t->header->bmin[2] + OFF) / CELL)); maxz = std::max(maxz, (int)floorf((t->header->bmax[2] + OFF) / CELL));
		}
		struct Cell { int cx, cy; unsigned char n[PER * PER]; std::vector<float> h; };
		std::vector<Cell> out;
		std::atomic<int> nextRow{ minz };
		std::atomic<long> layered{ 0 }, samples{ 0 };
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			std::vector<dtPolyRef> refs(8192);
			for (;;) {
				int cy = nextRow++;
				if (cy > maxz) break;
				std::vector<Cell> local;
				for (int cx = minx; cx <= maxx; cx++) {
					float c[3] = { (cx + 0.5f) * CELL - OFF, 0, (cy + 0.5f) * CELL - OFF };
					float ext[3] = { CELL / 2, 5000, CELL / 2 };
					int n = 0;
					q->queryPolygons(c, ext, &filter, refs.data(), &n, (int)refs.size());
					bool any = false;
					for (int i = 0; i < n && !any; i++) { int ci = compOf(refs[i]); any = ci >= 0 && compArea[ci] >= MIN_ISLAND; }
					if (!any) continue;
					Cell cell{ cx, cy, {}, {} };
					bool hit = false;
					for (int j = 0; j < PER; j++) for (int i = 0; i < PER; i++) {
						float p[3] = { cx * CELL - OFF + i * HS, 0, cy * CELL - OFF + j * HS };
						float e[3] = { 0.05f, 5000, 0.05f };
						int m = 0;
						dtPolyRef r[64];
						q->queryPolygons(p, e, &filter, r, &m, 64);
						std::vector<float> hs;
						for (int k = 0; k < m; k++) {
							int ci = compOf(r[k]);
							float h;
							if (ci < 0 || compArea[ci] < MIN_ISLAND || dtStatusFailed(q->getPolyHeight(r[k], p, &h))) continue;
							hs.push_back(h);
						}
						std::sort(hs.begin(), hs.end());
						std::vector<float> layers;
						for (float h : hs) if (layers.empty() || h - layers.back() > MERGE) layers.push_back(h);
						if ((int)layers.size() > MAX_LAYERS) layers.resize(MAX_LAYERS);
						cell.n[j * PER + i] = (unsigned char)layers.size();
						cell.h.insert(cell.h.end(), layers.begin(), layers.end());
						if (!layers.empty()) { hit = true; samples++; }
						if (layers.size() > 1) layered++;
					}
					if (hit) local.push_back(std::move(cell));
				}
				std::lock_guard<std::mutex> l(m);
				for (auto& cl : local) out.push_back(std::move(cl));
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		std::sort(out.begin(), out.end(), [](const Cell& a, const Cell& b) { return a.cy != b.cy ? a.cy < b.cy : a.cx < b.cx; });
		FILE* f = fopen(path.c_str(), "wb");
		uint32_t nc = (uint32_t)out.size();
		fwrite("HGT1", 1, 4, f);
		fwrite(&nc, 4, 1, f);
		for (auto& cl : out) {
			int32_t xy[2] = { cl.cx, cl.cy };
			fwrite(xy, 4, 2, f);
			fwrite(cl.n, 1, PER * PER, f);
			fwrite(cl.h.data(), 4, cl.h.size(), f);
		}
		fclose(f);
		printf("heights: %u cells, %ld ground samples, %ld with more than one layer\n", nc, samples.load(), layered.load());
	}

	void write(const std::string& path) {
		// drop dead nodes, dedupe edges
		std::vector<int> remap(nodes.size(), -1);
		uint32_t nn = 0;
		for (size_t i = 0; i < nodes.size(); i++) if (!dead[i]) remap[i] = (int)nn++;
		std::unordered_set<uint64_t> seen;
		std::vector<Edge> uniq;
		for (auto& e : edges) {
			int a = std::min(remap[e.a], remap[e.b]), b = std::max(remap[e.a], remap[e.b]);
			if (a == b || a < 0) continue;
			uint64_t k = ((uint64_t)a << 32) | (uint32_t)b;
			if (seen.insert(k).second) uniq.push_back({ a, b, e.flags });
		}
		if (getenv("NAV_DEBUG")) {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 4096);
			int hist[4] = { 0, 0, 0, 0 }, total = 0;
			for (size_t i = 0; i < nodes.size(); i++) {
				if (dead[i]) continue;
				float hd, hp[3], hn[3];
				if (dtStatusFailed(q->findDistanceToWall(nodes[i].ref, nodes[i].p, CLEAR, &filter, &hd, hp, hn))) continue;
				total++;
				hist[hd < 1 ? 0 : hd < 2 ? 1 : hd < 4 ? 2 : 3]++;
			}
			printf("wall clearance of nodes: <1 yd %.1f%%, 1-2 %.1f%%, 2-4 %.1f%%, 4+ %.1f%%\n", 100.0 * hist[0] / total,
				100.0 * hist[1] / total, 100.0 * hist[2] / total, 100.0 * hist[3] / total);
			dtFreeNavMeshQuery(q);
		}
		FILE* f = fopen(path.c_str(), "wb");
		uint32_t ne = (uint32_t)uniq.size();
		fwrite("GRF1", 1, 4, f);
		fwrite(&nn, 4, 1, f); fwrite(&ne, 4, 1, f);
		for (size_t i = 0; i < nodes.size(); i++) {
			if (dead[i]) continue;
			const Node& nd = nodes[i];
			// back to world coords: X = rc z, Y = rc x, Z = rc y
			float w[3] = { nd.p[2], nd.p[0], nd.p[1] };
			fwrite(w, 4, 3, f);
			unsigned char area = nd.area | (nd.poi ? 0x80 : 0); // high bit: a point of interest
			fwrite(&area, 1, 1, f);
		}
		for (auto& e : uniq) { int32_t ab[2] = { e.a, e.b }; fwrite(ab, 4, 2, f); fwrite(&e.flags, 1, 1, f); }
		fclose(f);
		printf("wrote %u nodes, %u edges\n", nn, ne);
	}
};

int main(int argc, char** argv) {
	if (argc < 5) { fprintf(stderr, "usage: navbuild tiles <geo_dir> <nav_dir> <threads> | graph <nav_dir> <out> <threads>\n"); return 1; }
	std::string cmd = argv[1];
	int threads = atoi(argv[4]);
	if (cmd == "tiles") return cmdTiles(argv[2], argv[3], threads);
	if (cmd == "probe") { // navbuild probe <nav_dir> <worldX> <worldY>
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		b.threads = 1;
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(b.nav, 4096);
		float c[3] = { (float)atof(argv[4]), 0, (float)atof(argv[3]) };
		float ext[3] = { CELL / 2, 5000, CELL / 2 };
		dtPolyRef refs[4096]; int n = 0;
		q->queryPolygons(c, ext, &b.filter, refs, &n, 4096);
		printf("%d polys\n", n);
		std::vector<std::array<float, 3>> pts;
		for (int i = 0; i < n && i < 12; i++) {
			float pt[3]; bool over;
			q->closestPointOnPoly(refs[i], c, pt, &over);
			pts.push_back({ pt[0], pt[1], pt[2] });
			printf("poly %d ref %llx area %d pt (%.1f %.1f %.1f)\n", i, (unsigned long long)refs[i], b.polyArea(refs[i]), pt[0], pt[1], pt[2]);
		}
		for (int i = 1; i < (int)pts.size(); i++) {
			unsigned char fl; float len = 0, dev = 0;
			dtPolyRef path[MAX_RAY_PATH]; dtRaycastHit hit{}; hit.path = path; hit.maxPath = MAX_RAY_PATH;
			dtStatus st = q->raycast(refs[0], pts[0].data(), pts[i].data(), &b.filter, 0, &hit);
			bool s1 = b.straight(q, refs[0], pts[0].data(), pts[i].data(), refs[i], fl);
			bool w = b.walk(q, refs[0], pts[0].data(), refs[i], pts[i].data(), len, dev, fl);
			printf("0->%d raycast status %x t %g pathCount %d last==target %d | straight %d walk %d len %.1f direct %.1f dev %.1f\n", i, st, hit.t, hit.pathCount,
				hit.pathCount ? path[hit.pathCount - 1] == refs[i] : -1, s1, w, len, dtVdist(pts[0].data(), pts[i].data()), dev);
		}
		return 0;
	}
	if (cmd == "line") { // navbuild line <nav_dir> <X1> <Y1> <Z1> <X2> <Y2> <Z2>: the edge checks between two world points (LINE_PROFILE=1: and the ground under it)
		if (argc < 9) return 1;
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		b.threads = 1;
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(b.nav, 4096);
		Node n[2];
		for (int k = 0; k < 2; k++) {
			float w[3] = { (float)atof(argv[3 + k * 3]), (float)atof(argv[4 + k * 3]), (float)atof(argv[5 + k * 3]) };
			float c[3] = { w[1], w[2], w[0] }, ext[3] = { 2, 4, 2 };
			q->findNearestPoly(c, ext, &b.filter, &n[k].ref, n[k].p);
			printf("point %d: poly %llx area %d at (%.2f %.2f %.2f)\n", k, (unsigned long long)n[k].ref, b.polyArea(n[k].ref), n[k].p[2], n[k].p[0], n[k].p[1]);
		}
		unsigned char fl = 0; float len = 0, dev = 0;
		bool s1 = b.straight(q, n[0].ref, n[0].p, n[1].p, n[1].ref, fl);
		printf("straight a->b %d flags %d\n", s1, fl);
		bool s2 = b.straight(q, n[1].ref, n[1].p, n[0].p, n[0].ref, fl);
		printf("straight b->a %d flags %d\n", s2, fl);
		bool w = b.walk(q, n[0].ref, n[0].p, n[1].ref, n[1].p, len, dev, fl);
		printf("walk %d len %.1f direct %.1f dev %.1f flags %d\n", w, len, dtVdist(n[0].p, n[1].p), dev, fl);
		float at[3]; bool drop = false;
		bool level = b.walksLevel(q, n[0].p, n[1].p, at, drop);
		printf("walks level %d%s\n", level, level ? "" : drop ? " (drop)" : " (hole)");
		if (!level) printf("  lost at (%.1f %.1f %.1f)\n", at[2], at[0], at[1]);
		if (getenv("LINE_PROFILE")) { // every walkable layer under the line, every yard: "profile <yards> <height>..."
			float d = dtVdist2D(n[0].p, n[1].p);
			for (int k = 0; k <= (int)d; k++) {
				float t = k / std::max(d, 0.01f), p[3] = { n[0].p[0] + (n[1].p[0] - n[0].p[0]) * t, 0, n[0].p[2] + (n[1].p[2] - n[0].p[2]) * t };
				float ext[3] = { 0.4f, 5000, 0.4f };
				dtPolyRef refs[128]; int m = 0;
				q->queryPolygons(p, ext, &b.filter, refs, &m, 128);
				printf("profile %d", k);
				for (int i = 0; i < m; i++) {
					float cp[3]; bool over;
					if (dtStatusSucceed(q->closestPointOnPoly(refs[i], p, cp, &over)) && dtVdist2D(cp, p) <= 0.3f) printf(" %.1f:%d", cp[1], b.polyArea(refs[i]));
				}
				printf("\n");
			}
		}
		return 0;
	}
	if (cmd == "walkcheck") { // navbuild walkcheck <nav_dir> <graph> <threads> [failures.txt]: walks every edge on the navmesh a yard at a time
		// (Builder::walksLevel) and list the edges that do not: a check of a .graph independent of its raycasts
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		if (!b.nav) return 1;
		FILE* f = fopen(argv[3], "rb");
		char magic[4]; uint32_t nn = 0, ne = 0;
		if (!f || fread(magic, 1, 4, f) != 4 || memcmp(magic, "GRF1", 4) || fread(&nn, 4, 1, f) != 1 || fread(&ne, 4, 1, f) != 1) { fprintf(stderr, "cannot read %s\n", argv[3]); return 1; }
		std::vector<std::array<float, 3>> pos(nn); // recast coords
		for (uint32_t i = 0; i < nn; i++) {
			float w[3]; unsigned char area;
			if (fread(w, 4, 3, f) != 3 || fread(&area, 1, 1, f) != 1) return 1;
			pos[i] = { w[1], w[2], w[0] };
		}
		std::vector<Edge> es(ne);
		for (uint32_t i = 0; i < ne; i++) {
			int32_t ab[2]; unsigned char fl;
			if (fread(ab, 4, 2, f) != 2 || fread(&fl, 1, 1, f) != 1) return 1;
			es[i] = { ab[0], ab[1], fl };
		}
		fclose(f);
		std::atomic<size_t> next{ 0 }, failed{ 0 }, failedLong{ 0 }, longEdges{ 0 }, drops{ 0 };
		std::mutex m;
		std::vector<std::string> shown;
		FILE* out = argc > 5 ? fopen(argv[5], "w") : nullptr; // every failing edge: ends, flags, kind, where, line height, depth of the ground under it
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(b.nav, 4096);
			for (;;) {
				size_t i = next++;
				if (i >= es.size()) break;
				const float* a = pos[es[i].a].data(); const float* e = pos[es[i].b].data();
				bool isLong = dtVdist2D(a, e) > 145;
				if (isLong) longEdges++;
				float at[3]; bool drop = false;
				if (b.walksLevel(q, a, e, at, drop)) continue;
				failed++;
				if (isLong) failedLong++;
				if (drop) drops++;
				if (out) {
					bool any;
					float under = b.groundNear(q, at, -1e6f, 0.3f, &any); // the lowest ground there
					float t = dtVdist2D(a, at) / std::max(0.01f, dtVdist2D(a, e));
					std::lock_guard<std::mutex> l(m);
					fprintf(out, "%.1f %.1f %.1f %.1f %.1f %.1f %d %s %.2f %.1f %.1f\n", a[2], a[0], a[1], e[2], e[0], e[1], es[i].flags,
						drop ? "drop" : "hole", std::min(t, 1 - t), at[1], under == FLT_MAX ? NAN : at[1] - under);
				}
				std::lock_guard<std::mutex> l(m);
				if (shown.size() < 25) {
					char line[256];
					snprintf(line, sizeof line, "  world (%.1f %.1f %.1f) - (%.1f %.1f %.1f), %.0f yd, flags %d: %s at (%.1f %.1f %.1f)",
						a[2], a[0], a[1], e[2], e[0], e[1], dtVdist2D(a, e), es[i].flags, drop ? "drop" : "hole", at[2], at[0], at[1]);
					shown.push_back(line);
				}
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < std::max(1, threads); i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		for (auto& s : shown) printf("%s\n", s.c_str());
		if (out) fclose(out);
		printf("edges walked: %u, off their ground: %zu (%.3f%%), %zu of them drops; long edges (over 145 yd): %zu, off their ground: %zu\n",
			ne, failed.load(), 100.0 * failed / std::max<uint32_t>(1, ne), drops.load(), longEdges.load(), failedLong.load());
		return 0;
	}
	if (cmd == "paths") { // navbuild paths <nav_dir> <pairs.txt> <threads>: Detour's string-pulled path per "X1 Y1 Z1 X2 Y2 Z2" line
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		b.threads = 1;
		dtNavMeshQuery* q = dtAllocNavMeshQuery();
		q->init(b.nav, 65535);
		FILE* f = fopen(argv[3], "r");
		if (!f) return 1;
		static dtPolyRef poly[16384];
		static float corners[2048 * 3];
		float w[6];
		for (int i = 0; fscanf(f, "%f %f %f %f %f %f", &w[0], &w[1], &w[2], &w[3], &w[4], &w[5]) == 6; i++) {
			Node n[2];
			for (int k = 0; k < 2; k++) {
				float c[3] = { w[k * 3 + 1], w[k * 3 + 2], w[k * 3] }, ext[3] = { 2, 4, 2 };
				q->findNearestPoly(c, ext, &b.filter, &n[k].ref, n[k].p);
			}
			int np = 0, nc = 0;
			if (!n[0].ref || !n[1].ref || dtStatusFailed(q->findPath(n[0].ref, n[1].ref, n[0].p, n[1].p, &b.filter, poly, &np, 16384)) || !np
				|| dtStatusFailed(q->findStraightPath(n[0].p, n[1].p, poly, np, corners, nullptr, nullptr, &nc, 2048))) {
				printf("%d none\n", i);
				continue;
			}
			float len = 0;
			for (int k = 1; k < nc; k++) len += dtVdist(&corners[(k - 1) * 3], &corners[k * 3]);
			printf("%d %.1f %d", i, len, nc);
			for (int k = 0; k < nc; k++) printf(" %.1f,%.1f,%.1f", corners[k * 3 + 2], corners[k * 3], corners[k * 3 + 1]);
			printf("\n");
		}
		fclose(f);
		return 0;
	}
	if (cmd == "walkgrid") { // navbuild walkgrid <nav_dir> <out.hgt3> <threads> <geo_dir>: the addon's walk grid
		// Every WG_HS yards on a grid aligned with the addon's 64-yard cells (HereBeDragons coords + 17100): every
		// walkable layer there or within REACH_POLY yards (a ramp or walkway narrower than the grid), from the navmesh,
		// at the height of the collision surface it lies on (the navmesh is within half a yard of it, but up to two
		// over rough ground). Points next to walkable ones that the navmesh misses (it keeps half a yard off walls and
		// edges, and narrow walkways may fall between points) get the surface continuing a neighbour's layer. Under
		// water only the surface counts (a swimmer stays on it). No layer where a player has no room to stand.
		// Each walkable layer also says where it ends towards each of its 4 neighbours that has no layer going on from
		// it (GeoCache::walkEdge: a drop, a slope too steep to walk, the end of a walkway), in 2/7 yards.
		// The steep grid: the ground within FLOOD points of walkable ground that is too steep to walk but a player
		// slides on (an embankment, a hillside), followed from the walkable layers over the collision surfaces.
		// HGT3 file: cell count, then per cell: cx, cy (int32), WG_PER x WG_PER walkable layer counts (uint8, rows of
		// x), their heights (float32), their edges (uint16: 3 bits per direction +x, -x, +y, -y from the low bits, 7
		// for none), the steep grid's layer counts (uint8) and heights (float32).
		static const float WG_HS = 2.0f, OFF = 17100.0f, MERGE = 1.5f, SNAP = 1.0f, SNAP_BELOW = 2.5f, GROW = 1.25f, UNDER_WATER = 40.0f, REACH_POLY = 1.0f, SWIM_DEPTH = 1.5f;
		static const float FIT = 1.3f + 1.3f * WG_HS; // the addon's CLIMB + SLOPE x one grid step: a neighbour's layer goes on from this one
		static const int WG_PER = 32, MAX_LAYERS = 6, FLOOD = 6, BORD = FLOOD + 1, BW = WG_PER + 2 * BORD;
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		if (!b.nav) return 1;
		b.labelComponents();
		std::string geoDir = argv[5];
		int minx = INT32_MAX, maxx = INT32_MIN, minz = INT32_MAX, maxz = INT32_MIN;
		for (int i = 0; i < b.nav->getMaxTiles(); i++) {
			const dtMeshTile* t = ((const dtNavMesh*)b.nav)->getTile(i);
			if (!t || !t->header) continue;
			minx = std::min(minx, (int)floorf((t->header->bmin[0] + OFF) / CELL)); maxx = std::max(maxx, (int)floorf((t->header->bmax[0] + OFF) / CELL));
			minz = std::min(minz, (int)floorf((t->header->bmin[2] + OFF) / CELL)); maxz = std::max(maxz, (int)floorf((t->header->bmax[2] + OFF) / CELL));
		}
		struct Cell { int cx, cy; unsigned char n[WG_PER * WG_PER], sn[WG_PER * WG_PER]; std::vector<float> h, sh; std::vector<uint16_t> e; };
		std::vector<Cell> out;
		std::mutex om;
		std::atomic<int> nextBand{ minz };
		std::atomic<long> samples{ 0 }, grown{ 0 }, snapped{ 0 }, layered{ 0 }, edged{ 0 }, steepPts{ 0 }, cramped{ 0 };
		static const int BAND = 8;
		int box[4] = { INT32_MIN, INT32_MIN, INT32_MAX, INT32_MAX }; // WG_BOX="cx0 cy0 cx1 cy1": only those cells (a test build)
		if (getenv("WG_BOX")) sscanf(getenv("WG_BOX"), "%d %d %d %d", &box[0], &box[1], &box[2], &box[3]);
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(b.nav, 4096);
			std::vector<dtPolyRef> refs(8192);
			GeoCache gc{ geoDir };
			std::vector<float> ghs;
			std::vector<unsigned char> gwet;
			std::vector<std::vector<float>> grid(BW * BW), walk(BW * BW), steep(BW * BW);
			auto P = [&](int i, int j) { return (j + BORD) * BW + (i + BORD); }; // i, j from -BORD
			for (;;) {
				int y0 = nextBand.fetch_add(BAND);
				if (y0 > maxz) break;
				std::vector<Cell> local;
				for (int cy = y0; cy < y0 + BAND && cy <= maxz; cy++) for (int cx = minx; cx <= maxx; cx++) {
					if (cx < box[0] || cy < box[1] || cx > box[2] || cy > box[3]) continue;
					float c[3] = { (cx + 0.5f) * CELL - OFF, 0, (cy + 0.5f) * CELL - OFF };
					float ext[3] = { CELL / 2 + 2, 5000, CELL / 2 + 2 };
					int n = 0;
					q->queryPolygons(c, ext, &b.filter, refs.data(), &n, (int)refs.size());
					bool any = false;
					for (int i = 0; i < n && !any; i++) { int ci = b.compOf(refs[i]); any = ci >= 0 && b.compArea[ci] >= MIN_ISLAND; }
					if (!any) continue;
					auto at = [&](int i, int j, float* p) { p[0] = cx * CELL - OFF + i * WG_HS; p[1] = 0; p[2] = cy * CELL - OFF + j * WG_HS; };
					// navmesh layers on the cell's points and a border of BORD points, snapped to the surfaces
					for (int j = -BORD; j < WG_PER + BORD; j++) for (int i = -BORD; i < WG_PER + BORD; i++) {
						auto& L = grid[P(i, j)];
						L.clear();
						float p[3];
						at(i, j, p);
						float e[3] = { REACH_POLY, 5000, REACH_POLY };
						int m = 0;
						dtPolyRef r[128];
						q->queryPolygons(p, e, &b.filter, r, &m, 128);
						std::vector<std::pair<float, bool>> hs; // height, on water
						for (int k = 0; k < m; k++) {
							int ci = b.compOf(r[k]);
							float h, cp[3];
							bool over;
							if (ci < 0 || b.compArea[ci] < MIN_ISLAND) continue;
							if (dtStatusFailed(q->getPolyHeight(r[k], p, &h))) { // within REACH_POLY of a polygon: its nearest point's height
								float pp[3] = { p[0], 0, p[2] };
								if (dtStatusFailed(q->closestPointOnPoly(r[k], pp, cp, &over)) || dtVdist2D(cp, pp) > REACH_POLY) continue;
								h = cp[1];
							}
							hs.push_back({ h, b.polyArea(r[k]) == A_SWIM });
						}
						std::sort(hs.begin(), hs.end());
						// a swimmer stays at the surface: no ground under water within UNDER_WATER yards of it
						float water = -FLT_MAX;
						for (auto& hw : hs) if (hw.second) water = std::max(water, hw.first);
						gc.at(p[0], p[2])->heightsAt(p[0], p[2], ghs, &gwet);
						for (auto& hw : hs) {
							float h = hw.first;
							if (!hw.second && h < water && h > water - UNDER_WATER) continue;
							if (!L.empty() && h - L.back() <= MERGE) continue;
							float s = gc.near(p[0], p[2], h, SNAP_BELOW, SNAP);
							if (s == s) { h = s; if (i >= 0 && j >= 0 && i < WG_PER && j < WG_PER) snapped++; }
							// ground under water deeper than SWIM_DEPTH: the swimmer is at the surface (the liquid the
							// geometry has over it, which the navmesh may not)
							float surface = FLT_MAX;
							surface = waterOver(ghs, gwet, h);
							if (surface > h + UNDER_WATER) surface = FLT_MAX;
							if (surface < FLT_MAX && surface - h > SWIM_DEPTH) h = surface;
							bool dup = false;
							for (float o : L) dup = dup || fabsf(o - h) <= MERGE;
							if (!dup) L.push_back(h);
						}
						std::sort(L.begin(), L.end());
					}
					// grow from walkable neighbours onto the surfaces continuing their layers
					for (int j = -BORD; j < WG_PER + BORD; j++) for (int i = -BORD; i < WG_PER + BORD; i++) {
						std::vector<float>& L = walk[P(i, j)];
						L = grid[P(i, j)];
						bool inner = i > -BORD && j > -BORD && i < WG_PER + BORD - 1 && j < WG_PER + BORD - 1;
						if (L.empty() && inner) {
							float p[3];
							at(i, j, p);
							for (int dj = -1; dj <= 1; dj++) for (int di = -1; di <= 1; di++) {
								for (float hn : grid[P(i + di, j + dj)]) {
									float s = gc.near(p[0], p[2], hn, GROW, GROW);
									if (s != s) continue;
									bool dup = false;
									for (float h : L) dup = dup || fabsf(h - s) <= MERGE;
									if (!dup) L.push_back(s);
								}
							}
							std::sort(L.begin(), L.end());
							if (!L.empty() && i >= 0 && j >= 0 && i < WG_PER && j < WG_PER) grown++;
						}
						if (!L.empty()) { // no layer where nobody fits (the ground under the low end of a ramp)
							float p[3];
							at(i, j, p);
							size_t k = 0;
							for (float h : L) if (gc.headroom(p[0], p[2], h)) L[k++] = h; else if (i >= 0 && j >= 0 && i < WG_PER && j < WG_PER) cramped++;
							L.resize(k);
						}
						if ((int)L.size() > MAX_LAYERS) L.resize(MAX_LAYERS);
						steep[P(i, j)].clear();
					}
					auto fits = [&](const std::vector<float>& L, float h, float tol) { for (float o : L) if (fabsf(o - h) <= tol) return true; return false; };
					// the steep grid: from the walkable layers with a neighbour they do not go on to, over the
					// surfaces a player slides on, up to FLOOD points out
					struct Q { int i, j; float h; int d; };
					std::vector<Q> queue;
					for (int j = -BORD + 1; j < WG_PER + BORD - 1; j++) for (int i = -BORD + 1; i < WG_PER + BORD - 1; i++)
						for (float h : walk[P(i, j)]) {
							bool edge = false;
							for (int dj = -1; dj <= 1 && !edge; dj++) for (int di = -1; di <= 1 && !edge; di++)
								if ((di || dj) && !fits(walk[P(i + di, j + dj)], h, FIT * (di && dj ? 1.42f : 1))) edge = true;
							if (edge) queue.push_back({ i, j, h, 0 });
						}
					for (size_t qi = 0; qi < queue.size(); qi++) {
						Q u = queue[qi];
						if (u.d >= FLOOD) continue;
						float a[3];
						at(u.i, u.j, a);
						for (int dj = -1; dj <= 1; dj++) for (int di = -1; di <= 1; di++) {
							int vi = u.i + di, vj = u.j + dj;
							if ((!di && !dj) || vi <= -BORD || vj <= -BORD || vi >= WG_PER + BORD - 1 || vj >= WG_PER + BORD - 1) continue;
							float e[3];
							at(vi, vj, e);
							float hv = gc.slideTo(a[0], a[2], u.h, e[0], e[2]);
							if (hv != hv || fits(walk[P(vi, vj)], hv, MERGE) || fits(steep[P(vi, vj)], hv, MERGE)) continue;
							if (gc.underWater(e[0], e[2], hv, SWIM_DEPTH) || !gc.headroom(e[0], e[2], hv)) continue;
							if ((int)steep[P(vi, vj)].size() >= MAX_LAYERS) continue;
							steep[P(vi, vj)].push_back(hv);
							queue.push_back({ vi, vj, hv, u.d + 1 });
						}
					}
					Cell cell{ cx, cy, {}, {}, {}, {}, {} };
					bool hit = false;
					static const int DI[4] = { 1, -1, 0, 0 }, DJ[4] = { 0, 0, 1, -1 };
					for (int j = 0; j < WG_PER; j++) for (int i = 0; i < WG_PER; i++) {
						const std::vector<float>& L = walk[P(i, j)];
						cell.n[j * WG_PER + i] = (unsigned char)L.size();
						cell.h.insert(cell.h.end(), L.begin(), L.end());
						float p[3];
						at(i, j, p);
						for (float h : L) { // where the layer ends towards each neighbour it does not go on to
							uint16_t code = 0;
							for (int d = 0; d < 4; d++) {
								int c7 = 7;
								if (!fits(walk[P(i + DI[d], j + DJ[d])], h, FIT)) {
									float len = gc.walkEdge(p[0], p[2], h, (float)DI[d], (float)DJ[d], WG_HS);
									if (len < WG_HS) { c7 = std::min(6, (int)floorf(len * 7 / WG_HS)); edged++; }
								}
								code |= (uint16_t)(c7 << (3 * d));
							}
							cell.e.push_back(code);
						}
						std::vector<float> S = steep[P(i, j)];
						std::sort(S.begin(), S.end());
						cell.sn[j * WG_PER + i] = (unsigned char)S.size();
						cell.sh.insert(cell.sh.end(), S.begin(), S.end());
						if (!S.empty()) steepPts++;
						if (!L.empty() || !S.empty()) { hit = true; if (!L.empty()) samples++; }
						if (L.size() > 1) layered++;
					}
					if (hit) local.push_back(std::move(cell));
				}
				std::lock_guard<std::mutex> l(om);
				for (auto& cl : local) out.push_back(std::move(cl));
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < std::max(1, threads); i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		std::sort(out.begin(), out.end(), [](const Cell& a, const Cell& c) { return a.cy != c.cy ? a.cy < c.cy : a.cx < c.cx; });
		FILE* f = fopen(argv[3], "wb");
		uint32_t nc = (uint32_t)out.size();
		fwrite("HGT3", 1, 4, f);
		fwrite(&nc, 4, 1, f);
		for (auto& cl : out) {
			int32_t xy[2] = { cl.cx, cl.cy };
			fwrite(xy, 4, 2, f);
			fwrite(cl.n, 1, WG_PER * WG_PER, f);
			fwrite(cl.h.data(), 4, cl.h.size(), f);
			fwrite(cl.e.data(), 2, cl.e.size(), f);
			fwrite(cl.sn, 1, WG_PER * WG_PER, f);
			fwrite(cl.sh.data(), 4, cl.sh.size(), f);
		}
		fclose(f);
		printf("walk grid: %u cells, %ld points with ground (%ld snapped to a surface, %ld grown from a neighbour), %ld with more than one layer, %ld layers left out without room to stand, %ld edges, %ld points of steep ground\n",
			nc, samples.load(), snapped.load(), grown.load(), layered.load(), cramped.load(), edged.load(), steepPts.load());
		return 0;
	}
	if (cmd == "geoat") { // navbuild geoat <geo_dir> <hbdX> <hbdY>: the collision surfaces over a point
		GeoCache gc{ argv[2] };
		float rx = (float)atof(argv[3]), rz = (float)atof(argv[4]);
		int col, row; tileOf(rx, rz, col, row);
		const GeoTile* t = gc.at(rx, rz);
		std::vector<float> hs;
		std::vector<unsigned char> wet;
		t->heightsAt(rx, rz, hs, &wet);
		printf("tile %d_%d (%zu triangles):", col, row, t->t.size() / 3);
		for (size_t i = 0; i < hs.size(); i++) printf(" %.2f%s", hs[i], wet[i] ? "(water)" : "");
		printf("\n");
		return 0;
	}
	if (cmd == "geoserve") { // navbuild geoserve <geo_dir> - -: answers tools/simdots.lua on stdin/stdout, a line each
		// (HereBeDragons x y): "w x y h tx ty maxDrop" -> "x y h share why" (GeoCache::walkTo, a real player's walk),
		// "n x y h r" -> the surface nearest h within r, or nan
		GeoCache gc{ argv[2] };
		gc.walls = true;
		char line[256];
		while (fgets(line, sizeof line, stdin)) {
			float x, y, h, tx, ty, d;
			if (line[0] == 'w' && sscanf(line + 2, "%f %f %f %f %f %f", &x, &y, &h, &tx, &ty, &d) == 6) {
				int why;
				float share = gc.walkTo(x, y, h, tx, ty, d, &why);
				printf("%.3f %.3f %.3f %.3f %d\n", x, y, h, share, why);
			} else if (line[0] == 'n' && sscanf(line + 2, "%f %f %f %f", &x, &y, &h, &d) == 4) {
				printf("%.3f\n", gc.near(x, y, h, d, d));
			} else printf("?\n");
			fflush(stdout);
		}
		return 0;
	}
	if (cmd == "geoats") { // navbuild geoats <geo_dir> < points: geoat for each "hbdX hbdY" line, "x y h h ..." out
		GeoCache gc{ argv[2] };
		float rx, rz;
		std::vector<float> hs;
		while (scanf("%f %f", &rx, &rz) == 2) {
			hs.clear();
			const GeoTile* t = gc.at(rx, rz);
			if (t) t->heightsAt(rx, rz, hs, nullptr);
			printf("%.2f %.2f", rx, rz);
			for (float h : hs) printf(" %.2f", h);
			printf("\n");
		}
		return 0;
	}
	if (cmd == "simtruth") { // navbuild simtruth <geo_dir> <sim.tsv> <threads> <out.tsv>: true ground for tools/simdots.lua
		// Walks the collision surfaces half a yard at a time (GeoCache::step: up stairs and kerbs, down ledges)
		// along each step's dot line from the player's true height (simdots' walker, on the same surfaces), and
		// writes "P route step x y along addonZ trueZ localCorners" and "D route step along x y addonZ trueZ nearestZ"
		// (nearestZ: the surface nearest the addon's height there).
		if (argc < 6) return 1;
		struct Step { int step; float x, y, along, pz; int k, js; float ax, ay; std::vector<std::array<float, 2>> lc; std::vector<std::array<float, 4>> dots; std::vector<std::array<float, 2>> truth; float pTrue; };
		struct Route { int id; std::vector<std::array<float, 3>> c; std::vector<Step> steps; };
		std::vector<Route> routes;
		std::unordered_map<int, size_t> byId;
		FILE* f = fopen(argv[3], "r");
		if (!f) return 1;
		static char line[1 << 16];
		while (fgets(line, sizeof line, f)) {
			if (line[0] == 'R') {
				Route r; char* p = line + 2; int inst, used;
				if (sscanf(p, "%d %d %*s%n", &r.id, &inst, &used) < 2) continue;
				p += used;
				float x, y, z;
				while (sscanf(p, "%f %f %f%n", &x, &y, &z, &used) == 3) { r.c.push_back({ x, y, z }); p += used; }
				byId[r.id] = routes.size();
				routes.push_back(std::move(r));
			} else if (line[0] == 'P') {
				Step s; int id, nlc = 0, used = 0;
				if (sscanf(line + 2, "%d %d %f %f %f %f %d %f %f %f %d %d%n", &id, &s.step, &s.x, &s.y, &s.along, &s.pz, &s.k, &s.ax, &s.ay, &s.pTrue, &s.js, &nlc, &used) == 12) {
					char* q = line + 2 + used;
					for (int k = 0; k < nlc; k++) { float cx, cy; int u2; if (sscanf(q, "%f %f%n", &cx, &cy, &u2) != 2) break; s.lc.push_back({ cx, cy }); q += u2; }
					routes[byId[id]].steps.push_back(std::move(s));
				}
			} else if (line[0] == 'D') {
				int id, step; float a, x, y, z;
				if (sscanf(line + 2, "%d %d %f %f %f %f", &id, &step, &a, &x, &y, &z) == 6) {
					Route& r = routes[byId[id]];
					if (!r.steps.empty() && r.steps.back().step == step) r.steps.back().dots.push_back({ a, x, y, z });
				}
			}
		}
		fclose(f);
		// HBD (x = world Y, y = world X) to recast (world Y, Z, world X)
		auto rc = [](float x, float y, float z, float* o) { o[0] = x; o[1] = z; o[2] = y; };
		// walk a polyline (recast points) from height h, calling at(alongYards, height) every half yard; at each
		// corner back on the corner's own surface when within reach
		auto follow = [&](GeoCache& gc, const std::vector<std::array<float, 3>>& pts, float h, float maxAlong, const std::function<void(float, float)>& at) {
			float along = 0;
			at(0, h);
			for (size_t i = 0; i + 1 < pts.size() && along < maxAlong; i++) {
				const float* a = pts[i].data(); const float* e = pts[i + 1].data();
				float len = dtVdist2D(a, e);
				int n = std::max(1, (int)ceilf(len / 0.5f));
				for (int k = 1; k <= n; k++) {
					float t = (float)k / n;
					h = gc.step(a[0] + (e[0] - a[0]) * t, a[2] + (e[2] - a[2]) * t, h, (e[0] - a[0]) / std::max(len, 1e-3f), (e[2] - a[2]) / std::max(len, 1e-3f));
					at(along + len * t, h);
				}
				along += len;
				float ce = gc.near(e[0], e[2], e[1], 6.0f, 6.0f); // a corner's navmesh height is only near the surface
				if (ce == ce && fabsf(ce - h) <= Builder::WALK_END * 2) h = ce;
			}
		};
		std::atomic<size_t> next{ 0 };
		auto worker = [&]() {
			GeoCache gc{ argv[2] };
			for (;;) {
				size_t ri = next++;
				if (ri >= routes.size()) break;
				Route& r = routes[ri];
				std::vector<std::array<float, 3>> pts;
				for (auto& c : r.c) { float o[3]; rc(c[0], c[1], c[2], o); pts.push_back({ o[0], o[1], o[2] }); }
				for (auto& s : r.steps) {
					float o[3];
					// the dots' line: the player's own way onto the route (its last corner the join point, on the route's leg
					// from corner js, at the route's height there), then the route's corners after it
					std::vector<std::array<float, 3>> line;
					rc(s.x, s.y, s.pTrue, o); line.push_back({ o[0], o[1], o[2] });
					int js = std::max(1, std::min(s.js, (int)r.c.size()));
					for (size_t k = 0; k < s.lc.size(); k++) {
						float z = s.pTrue;
						if (k + 1 == s.lc.size() && js < (int)r.c.size()) {
							const auto& a = r.c[js - 1]; const auto& b = r.c[js];
							float dx = b[0] - a[0], dy = b[1] - a[1], L2 = dx * dx + dy * dy;
							float t = L2 > 0 ? std::max(0.0f, std::min(1.0f, ((s.lc[k][0] - a[0]) * dx + (s.lc[k][1] - a[1]) * dy) / L2)) : 0;
							z = a[2] + (b[2] - a[2]) * t;
						}
						rc(s.lc[k][0], s.lc[k][1], z, o);
						// on the route the join point is the player's own spot: no leg without a direction to look ahead in
						if (dtVdist2D(o, line.back().data()) > 0.05f) line.push_back({ o[0], o[1], o[2] });
					}
					for (int k = js + 1; k <= (int)r.c.size(); k++) line.push_back(pts[k - 1]);
					float maxA = 0;
					for (auto& d : s.dots) maxA = std::max(maxA, d[0]);
					std::vector<std::pair<float, float>> dp;
					follow(gc, line, s.pTrue, maxA + 1, [&](float a, float h) { dp.push_back({ a, h }); });
					for (auto& d : s.dots) {
						auto it = std::lower_bound(dp.begin(), dp.end(), std::make_pair(d[0] - 0.26f, -FLT_MAX));
						float zt = it == dp.end() ? NAN : it->second;
						float p[3]; rc(d[1], d[2], d[3], p);
						s.truth.push_back({ zt, gc.near(p[0], p[2], d[3], 50, 50) });
					}
				}
			}
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < std::max(1, threads); i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
		FILE* out = fopen(argv[5], "w");
		for (auto& r : routes) for (auto& s : r.steps) {
			fprintf(out, "P %d %d %.2f %.2f %.2f %.2f %.2f %d\n", r.id, s.step, s.x, s.y, s.along, s.pz, s.pTrue, (int)s.lc.size());
			for (size_t i = 0; i < s.dots.size(); i++)
				fprintf(out, "D %d %d %.2f %.2f %.2f %.2f %.2f %.2f\n", r.id, s.step, s.dots[i][0], s.dots[i][1], s.dots[i][2], s.dots[i][3], s.truth[i][0], s.truth[i][1]);
		}
		fclose(out);
		printf("simtruth: %zu routes\n", routes.size());
		return 0;
	}
	if (cmd == "heights") {
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		if (!b.nav) return 1;
		b.threads = threads;
		b.labelComponents();
		b.heights(argv[3]);
		return 0;
	}
	if (cmd == "graph") {
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		if (!b.nav) return 1;
		b.threads = threads;
		b.labelComponents();
		b.sampleCells();
		if (argc > 5) b.addPois(argv[5]);
		b.connect();
		b.longRuns();
		b.simplify();
		b.dropOffLevel();
		b.shortcuts();
		b.verify();
		b.write(argv[3]);
		return 0;
	}
	return 1;
}
