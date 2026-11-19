-- fleet coordinator initialisation: extensions, schema, seed data.
-- Workers are registered afterwards by scripts/bootstrap.sh.

CREATE EXTENSION IF NOT EXISTS citus;
CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------------
-- fleets: one row per fleet operator (10,000 rows)
-- ---------------------------------------------------------------------------
CREATE TABLE fleets (
    fleet_id   bigint PRIMARY KEY,
    fleet_name text NOT NULL,
    home_city  text NOT NULL
);

INSERT INTO fleets (fleet_id, fleet_name, home_city)
VALUES
    (1, 'metro_cabs',        'Metro Cabs'),
    (2, 'harbor_logistics',  'Harbor Logistics'),
    (3, 'golden_gate_rides', 'Golden Gate Rides');

INSERT INTO fleets (fleet_id, fleet_name, home_city)
SELECT g, 'fleet_' || g, 'Fleet ' || g
FROM generate_series(4, 10000) AS g;

-- ---------------------------------------------------------------------------
-- vehicles: one row per vehicle (~4 per fleet, 40,000 rows)
-- last_known_location is the vehicle's most recent GPS fix (WGS84 lon/lat)
-- ---------------------------------------------------------------------------
CREATE TABLE vehicles (
    fleet_id            bigint NOT NULL,
    vehicle_id          bigint NOT NULL,
    license_plate       text NOT NULL,
    status              text NOT NULL DEFAULT 'active',
    last_known_location geometry(Point, 4326),
    PRIMARY KEY (fleet_id, vehicle_id)
);

INSERT INTO vehicles (fleet_id, vehicle_id, license_plate, status, last_known_location)
SELECT s.fleet_id, v,
       'FL-' || s.fleet_id || '-' || v,
       CASE WHEN (s.fleet_id + v) % 7 = 0 THEN 'maintenance' ELSE 'active' END,
       -- scatter fixes around the NYC metro area, deterministic per vehicle
       ST_SetSRID(ST_MakePoint(
           -74.2 + ((s.fleet_id * 31 + v * 17) % 600) / 1000.0,
            40.5 + ((s.fleet_id * 13 + v * 29) % 500) / 1000.0), 4326)
FROM fleets s, generate_series(1, 4) AS v;

-- ---------------------------------------------------------------------------
-- trips: one row per completed trip (~5 per fleet, 50,000 rows)
-- fleet_id is the fleet that operated the trip
-- ---------------------------------------------------------------------------
CREATE TABLE trips (
    fleet_id    bigint NOT NULL,
    trip_id     bigint NOT NULL,
    vehicle_id  bigint NOT NULL,
    distance_km numeric(8,2) NOT NULL,
    fare_usd    numeric(8,2) NOT NULL
);

INSERT INTO trips (fleet_id, trip_id, vehicle_id, distance_km, fare_usd)
SELECT s.fleet_id, t, (t % 4) + 1,
       ((s.fleet_id * 11 + t * 7) % 400 + 10)::numeric(8,2) / 10,
       ((s.fleet_id *  5 + t * 3) % 900 + 80)::numeric(8,2) / 10
FROM fleets s, generate_series(1, 5) AS t;

-- ---------------------------------------------------------------------------
-- vehicles_by_region: one row per vehicle. Starts as a local table — Lab 6
-- distributes it by region (8 shards). Deliberately skewed: 'NA' holds ~60%
-- of rows so learners can observe what a low-cardinality shard key does to
-- data spread.
-- ---------------------------------------------------------------------------
-- NOTE: the primary key must include the distribution column (region) — a
-- Citus rule the course covers in module 04.
CREATE TABLE vehicles_by_region (
    vehicle_id    bigint NOT NULL,
    license_plate text NOT NULL,
    region        text NOT NULL,
    PRIMARY KEY (region, vehicle_id)
);

INSERT INTO vehicles_by_region (vehicle_id, license_plate, region)
SELECT g, 'V-' || g,
       CASE
           WHEN g <= 6000 THEN 'NA'
           WHEN g <= 7500 THEN 'EU'
           WHEN g <= 8500 THEN 'APAC'
           WHEN g <= 9500 THEN 'LATAM'
           ELSE 'MEA'
       END
FROM generate_series(1, 10000) AS g;

-- ---------------------------------------------------------------------------
-- service_zones: geofence polygons the platform matches GPS pings against
-- (airport pickups, congestion zones, depots). Small enough that Lab 7 turns
-- it into a reference table — a full copy on every worker, so spatial joins
-- against telematics shards never cross the network.
-- ---------------------------------------------------------------------------
CREATE TABLE service_zones (
    zone_id   int PRIMARY KEY,
    zone_name text NOT NULL,
    boundary  geometry(Polygon, 4326) NOT NULL
);

INSERT INTO service_zones (zone_id, zone_name, boundary) VALUES
(1, 'JFK Airport',
 ST_GeomFromText('POLYGON((-73.83 40.62, -73.74 40.62, -73.74 40.68, -73.83 40.68, -73.83 40.62))', 4326)),
(2, 'Newark Airport',
 ST_GeomFromText('POLYGON((-74.20 40.66, -74.15 40.66, -74.15 40.72, -74.20 40.72, -74.20 40.66))', 4326)),
(3, 'Manhattan CBD',
 ST_GeomFromText('POLYGON((-74.02 40.70, -73.93 40.70, -73.93 40.88, -74.02 40.88, -74.02 40.70))', 4326)),
(4, 'Port Newark',
 ST_GeomFromText('POLYGON((-74.16 40.67, -74.10 40.67, -74.10 40.71, -74.16 40.71, -74.16 40.67))', 4326)),
(5, 'LaGuardia Airport',
 ST_GeomFromText('POLYGON((-73.89 40.76, -73.85 40.76, -73.85 40.79, -73.89 40.79, -73.89 40.76))', 4326));

-- NOTE: nothing in this file is distributed — every table starts as a local
-- table on the coordinator. The labs distribute them one by one (Lab 3:
-- fleets; Lab 6: vehicles_by_region, vehicles, trips). Distributing here
-- would be wrong anyway: the workers aren't registered yet at init time, so
-- the shards would all land on the coordinator.
