// navbuild: Recast/Detour navmesh tiles from .geo files, then a sparse walkable-path graph.
//
//   navbuild tiles <geo_dir> <nav_dir> <threads>        one .nav per ADT tile (4x4 Detour tiles)
//   navbuild graph <nav_dir> <out.graph> <threads>      graph over the whole map (NAV_DEBUG=1 for island and edge stats)
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
#include <mutex>
#include <queue>
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
static const float SMALL_PROP = 4.0f;        // yards: M2 props narrower than this are not obstacles
static const float AGENT_HEIGHT = 2.0f, AGENT_CLIMB = 1.25f, AGENT_RADIUS = 0.5f, MAX_SLOPE = 52.0f;

enum Area : unsigned char { A_NULL = 0, A_GROUND = 1, A_SWIM = 2, A_INDOOR = 3 };

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

// Standalone M2 props with a small footprint (tree trunks, posts, lamps, barrels, small rocks) are left out:
// the player steers around them, and keeping them shreds open ground into slivers the graph has to route around.
static void dropSmallProps(Geo& g) {
	std::unordered_map<int64_t, std::array<float, 4>> box;
	size_t nt = g.a.size();
	for (size_t i = 0; i < nt; i++) {
		int64_t k = g.k[i];
		if (k < 0 || (k & 1)) continue;
		auto it = box.emplace(k, std::array<float, 4>{ FLT_MAX, FLT_MAX, -FLT_MAX, -FLT_MAX }).first;
		for (int j = 0; j < 3; j++) {
			const float* v = &g.v[g.t[i * 3 + j] * 3];
			auto& b = it->second;
			b[0] = std::min(b[0], v[0]); b[1] = std::min(b[1], v[2]); b[2] = std::max(b[2], v[0]); b[3] = std::max(b[3], v[2]);
		}
	}
	std::unordered_set<int64_t> small;
	for (auto& kv : box) if (std::max(kv.second[2] - kv.second[0], kv.second[3] - kv.second[1]) < SMALL_PROP) small.insert(kv.first);
	if (small.empty()) return;
	size_t w = 0;
	for (size_t i = 0; i < nt; i++) {
		if (g.k[i] >= 0 && small.count(g.k[i])) continue;
		for (int j = 0; j < 3; j++) g.t[w * 3 + j] = g.t[i * 3 + j];
		g.a[w] = g.a[i]; g.k[w] = g.k[i];
		w++;
	}
	g.t.resize(w * 3); g.a.resize(w); g.k.resize(w);
}

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
	dropSmallProps(out);
}

struct NavBlob { int tx, ty; std::vector<unsigned char> data; };

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

struct Node { float p[3]; dtPolyRef ref; int cx, cz; unsigned char area; };
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
		filter.setAreaCost(A_SWIM, 1.7f);
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

	unsigned char polyArea(dtPolyRef ref) {
		const dtMeshTile* tile; const dtPoly* poly;
		if (dtStatusFailed(nav->getTileAndPolyByRef(ref, &tile, &poly))) return 0;
		return poly->getArea();
	}

	// Shortest navmesh walk from a to b: length, largest sideways deviation from the straight line,
	// swim flag and the corner points. False when b is unreachable within the search budget.
	bool walk(dtNavMeshQuery* q, dtPolyRef aRef, const float* a, dtPolyRef bRef, const float* b,
		float& len, float& dev, unsigned char& flags, std::vector<std::array<float, 3>>* corners = nullptr,
		std::vector<dtPolyRef>* cornerRefs = nullptr) {
		dtPolyRef path[512];
		int np = 0;
		if (dtStatusFailed(q->findPath(aRef, bRef, a, b, &filter, path, &np, 512)) || np == 0 || path[np - 1] != bRef) return false;
		float sp[128 * 3]; unsigned char spf[128]; dtPolyRef spr[128]; int ns = 0;
		if (dtStatusFailed(q->findStraightPath(a, b, path, np, sp, spf, spr, &ns, 128, 0)) || ns < 2) return false;
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
		flags = 0;
		for (int i = 0; i < np; i++) if (polyArea(path[i]) == A_SWIM) flags = 1;
		return true;
	}

	// Straight walk check from a to b on the navmesh. flags: 1 if any swim polygon is crossed.
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
		flags = 0;
		for (int i = 0; i < hit.pathCount; i++) if (polyArea(path[i]) == A_SWIM) flags = 1;
		return true;
	}

	// Close enough to straight that the player just steers around (tree trunks, posts, rocks).
	bool nearlyStraight(dtNavMeshQuery* q, const Node& a, const Node& b, unsigned char& flags) {
		if (straight(q, a.ref, a.p, b.p, b.ref, flags) || straight(q, b.ref, b.p, a.p, a.ref, flags)) return true;
		float len, dev;
		if (!walk(q, a.ref, a.p, b.ref, b.p, len, dev, flags)) return false;
		float d = dtVdist(a.p, b.p);
		return len <= d * 1.06f + 1.0f && dev <= std::max(3.5f, d * 0.07f);
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
				for (auto& nd : local) { cells[{ nd.cx, nd.cz }].push_back((int)nodes.size()); nodes.push_back(nd); }
			}
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();
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

	void connect() {
		static const int OFF[16][2] = { {1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1},
			{2,1},{2,-1},{-2,1},{-2,-1},{1,2},{1,-2},{-1,2},{-1,-2} };
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
				for (int o = 0; o < 16; o++) {
					auto it = cells.find({ a.cx + OFF[o][0], a.cz + OFF[o][1] });
					if (it == cells.end()) continue;
					for (int j : it->second) {
						if (j <= (int)i) continue; // each pair once
						const Node& b = nodes[j];
						if (fabsf(a.p[1] - b.p[1]) > 60 || compOf(a.ref) != compOf(b.ref)) continue;
						unsigned char fl;
						if (nearlyStraight(q, a, b, fl)) le.push_back({ (int)i, j, fl });
						else {
							if (o < 8) lm.push_back({ (int)i, j });
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
		edges = found;
		printf("direct edges: %zu, pairs to route around obstacles: %zu\n", edges.size(), missing.size());
		repair(missing);
	}

	// For neighbouring cells without a straight walk, follow the navmesh path and add its corners.
	void repair(const std::vector<std::pair<int, int>>& pairs) {
		std::atomic<size_t> next{ 0 };
		struct Route { int a, b; float len; std::vector<std::array<float, 3>> pts; std::vector<dtPolyRef> refs; std::vector<unsigned char> fl; };
		std::vector<Route> routes;
		auto worker = [&]() {
			dtNavMeshQuery* q = dtAllocNavMeshQuery();
			q->init(nav, 8192);
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
				r.len = len;
				r.fl.assign(r.pts.size(), fl);
				lr.push_back(std::move(r));
			}
			std::lock_guard<std::mutex> l(m);
			for (auto& r : lr) routes.push_back(std::move(r));
			dtFreeNavMeshQuery(q);
		};
		std::vector<std::thread> pool;
		for (int i = 0; i < threads; i++) pool.emplace_back(worker);
		for (auto& t : pool) t.join();

		// Shortest routes first; a route is only added when the graph has no path within 20% of it already
		// (a greedy spanner), and its corners reuse any node within SNAP yards.
		std::sort(routes.begin(), routes.end(), [](const Route& x, const Route& y) { return x.len < y.len; });
		const float SNAP = 6.0f;
		std::vector<std::vector<std::pair<int, float>>> adj(nodes.size());
		auto link = [&](int a, int b, unsigned char fl) {
			edges.push_back({ a, b, fl });
			float d = dtVdist(nodes[a].p, nodes[b].p);
			adj[a].push_back({ b, d }); adj[b].push_back({ a, d });
		};
		for (auto& e : edges) { float d = dtVdist(nodes[e.a].p, nodes[e.b].p); adj[e.a].push_back({ e.b, d }); adj[e.b].push_back({ e.a, d }); }
		std::vector<float> dist;
		std::vector<int> touched;
		auto within = [&](int s, int t, float limit) {
			dist.resize(nodes.size(), FLT_MAX);
			std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>, std::greater<>> pq;
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
			for (int x : touched) dist[x] = FLT_MAX;
			touched.clear();
			return found;
		};
		std::map<std::tuple<int, int, int>, std::vector<int>> grid;
		auto key = [&](const float* p) { return std::make_tuple((int)floorf(p[0] / SNAP), (int)floorf(p[1] / SNAP), (int)floorf(p[2] / SNAP)); };
		for (size_t i = 0; i < nodes.size(); i++) grid[key(nodes[i].p)].push_back((int)i);
		auto nodeFor = [&](const std::array<float, 3>& p, dtPolyRef ref) {
			auto k = key(p.data());
			for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) {
				auto it = grid.find({ std::get<0>(k) + dx, std::get<1>(k) + dy, std::get<2>(k) + dz });
				if (it == grid.end()) continue;
				for (int id : it->second) if (dtVdistSqr(nodes[id].p, p.data()) < SNAP * SNAP) return id;
			}
			Node nd; nd.p[0] = p[0]; nd.p[1] = p[1]; nd.p[2] = p[2]; nd.ref = ref;
			nd.cx = (int)floorf(p[0] / CELL); nd.cz = (int)floorf(p[2] / CELL); nd.area = polyArea(ref);
			int id = (int)nodes.size();
			nodes.push_back(nd);
			adj.emplace_back();
			grid[k].push_back(id);
			return id;
		};
		size_t before = nodes.size(), used = 0;
		for (auto& r : routes) {
			if (within(r.a, r.b, r.len * 1.2f + 8.0f)) continue;
			used++;
			int prev = r.a;
			for (size_t k = 1; k + 1 < r.pts.size(); k++) {
				int id = nodeFor(r.pts[k], r.refs[k] ? r.refs[k] : nodes[prev].ref);
				if (id != prev) link(prev, id, r.fl[k - 1]);
				prev = id;
			}
			if (prev != r.b) link(prev, r.b, r.fl.back());
		}
		printf("routes added: %zu of %zu\n", used, routes.size());
		printf("routed pairs: %zu, corner nodes added: %zu\n", routes.size(), nodes.size() - before);
		dead.assign(nodes.size(), 0);
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
				unsigned char fl;
				if (!nearlyStraight(q, nodes[a], nodes[b], fl)) continue;
				fl |= adj[v][a] | adj[v][b];
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
			fwrite(&nd.area, 1, 1, f);
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
	if (cmd == "graph") {
		Builder b;
		b.nav = loadNavMesh(argv[2]);
		if (!b.nav) return 1;
		b.threads = threads;
		b.labelComponents();
		b.sampleCells();
		b.connect();
		b.simplify();
		b.write(argv[3]);
		return 0;
	}
	return 1;
}
