-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Joel Haasnoot
--
-- Tile functions for offline packs, loaded after the upstream import (see build-country.sh).

-- railway_line_high for the app. From zoom 10 it is upstream's function (import/sql/tile_views.sql)
-- plus the OSM `layer` of each way, which the app's style uses to draw higher bridges over lower
-- ones (see pipeline/prepare_style.py). Below zoom 10, ways that would be drawn the same are merged
-- into one feature per tile: OSM splits a line into many short ways wherever any tag changes, and
-- at low zoom a tile would otherwise hold tens of thousands of tiny features that phones must
-- filter one by one for every style layer.
--
-- The grouping columns are the properties the app's style reads from railway_line_high below zoom
-- 10, in any view. Bridges and tunnels stay separate ways because the style only draws the long ones
-- (by way_length). Other columns are left out at these zooms; the style does not use them there.
-- The zoom filters repeat the ones in upstream's railway_line_high.
CREATE OR REPLACE FUNCTION railway_line_high_offline(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE SQL
  IMMUTABLE
  STRICT
  PARALLEL SAFE
RETURN (
  CASE WHEN z >= 10 THEN (
    SELECT
      ST_AsMVT(tile, 'railway_line_high', 4096, 'way')
    FROM (
      SELECT
        id,
        ST_AsMVTGeom(way, ST_TileEnvelope(z, x, y), extent => 4096, buffer => 64, clip_geom => true) AS way,
        way_length,
        layer,
        feature,
        state,
        usage,
        service,
        highspeed,
        preserved,
        tunnel,
        bridge,
        name,
        ref,
        track_ref,
        track_class,
        preferred_direction,
        rank,
        maxspeed,
        speed_label,
        train_protection_rank,
        train_protection[1] AS train_protection0,
        train_protection[2] AS train_protection1,
        train_protection[3] AS train_protection2,
        train_protection_construction_rank,
        train_protection_construction,
        electrification_state,
        voltage,
        frequency,
        maximum_current,
        future_voltage,
        future_frequency,
        future_maximum_current,
        array_to_string(gauges, ', ') AS gauges,
        gaugeint0,
        gauge0,
        gaugeint1,
        gauge1,
        gaugeint2,
        gauge2,
        loading_gauge,
        operator,
        operator_color,
        operator_bright,
        primary_operator,
        owner,
        route_count,
        passenger_lines,
        rack,
        radio
      FROM railway_line_view
      WHERE
        way && ST_TileEnvelope(z, x, y)
        AND CASE
          WHEN z < 11 THEN
            state IN ('present', 'construction', 'proposed')
              AND service IS NULL
              AND (
                feature IN ('rail', 'ferry', 'narrow_gauge', 'light_rail', 'monorail', 'subway', 'tram')
              )
          WHEN z < 12 THEN
            state IN ('present', 'construction', 'proposed', 'disused')
              AND (service IS NULL OR service IN ('spur', 'yard'))
              AND (
                feature IN ('rail', 'ferry', 'narrow_gauge', 'light_rail')
                  OR (feature IN ('monorail', 'subway', 'tram') AND service IS NULL)
              )
          ELSE
            true
        END
      ORDER BY
        coalesce(layer, 0),
        rank NULLS LAST,
        maxspeed NULLS FIRST
    ) AS tile
    WHERE way IS NOT NULL
  ) ELSE (
    SELECT
      ST_AsMVT(tile, 'railway_line_high', 4096, 'way')
    FROM (
      SELECT
        min(id) AS id,
        ST_AsMVTGeom(ST_LineMerge(ST_Collect(way)), ST_TileEnvelope(z, x, y), extent => 4096, buffer => 64, clip_geom => true) AS way,
        sum(way_length) AS way_length,
        coalesce(layer, 0) AS layer,
        feature,
        state,
        usage,
        service,
        highspeed,
        tunnel,
        bridge,
        name,
        ref,
        track_class,
        rank,
        maxspeed,
        speed_label,
        train_protection_rank,
        train_protection[1] AS train_protection0,
        train_protection[2] AS train_protection1,
        train_protection[3] AS train_protection2,
        train_protection_construction_rank,
        train_protection_construction,
        electrification_state,
        voltage,
        frequency,
        maximum_current,
        future_voltage,
        future_frequency,
        future_maximum_current,
        array_to_string(gauges, ', ') AS gauges,
        gaugeint0,
        gauge0,
        gaugeint1,
        gauge1,
        gaugeint2,
        gauge2,
        loading_gauge,
        operator_color,
        primary_operator,
        route_count,
        passenger_lines,
        radio
      FROM railway_line_view
      WHERE
        way && ST_TileEnvelope(z, x, y)
        AND CASE
          WHEN z < 8 THEN
            state = 'present'
              AND service IS NULL
              AND (
                feature IN ('rail', 'ferry') AND usage IN ('main', 'branch')
              )
          WHEN z < 9 THEN
            state IN ('present', 'construction', 'proposed')
              AND service IS NULL
              AND (
                feature IN ('rail', 'ferry') AND usage IN ('main', 'branch')
              )
          ELSE
            state IN ('present', 'construction', 'proposed')
              AND service IS NULL
              AND (
                feature IN ('rail', 'ferry') AND usage IN ('main', 'branch', 'industrial')
                  OR (feature = 'light_rail' AND usage IN ('main', 'branch'))
              )
        END
      GROUP BY
        coalesce(layer, 0),
        CASE WHEN tunnel OR bridge THEN id END,
        feature, state, usage, service, highspeed, tunnel, bridge, name, ref, track_class, rank, maxspeed,
        speed_label, train_protection_rank, train_protection, train_protection_construction_rank,
        train_protection_construction, electrification_state, voltage, frequency, maximum_current,
        future_voltage, future_frequency, future_maximum_current, gauges, gaugeint0, gauge0, gaugeint1,
        gauge1, gaugeint2, gauge2, loading_gauge, operator_color, primary_operator, route_count, passenger_lines,
        radio
      ORDER BY
        coalesce(layer, 0),
        rank NULLS LAST,
        maxspeed NULLS FIRST
    ) AS tile
    WHERE way IS NOT NULL
  ) END
);

-- Upstream's level_crossings_grouped and level_crossings_grouped_buffered read
-- level_crossings_grouped_view, which joins every group to pois and aggregates them all before the
-- tile filter, so it cannot use the spatial index: about 0.8 s per tile on Poland. Both functions
-- only need columns of the materialized table level_crossings_grouped (import/sql/stations_clustered.sql),
-- whose buffered column is indexed, so they read that instead (a few ms per tile). CREATE OR REPLACE
-- keeps upstream's function comments, which martin reads for the layer fields.
CREATE OR REPLACE FUNCTION level_crossings_grouped(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE SQL
  IMMUTABLE
  STRICT
  PARALLEL SAFE
RETURN (
  SELECT
    ST_AsMVT(tile, 'level_crossings_grouped', 4096, 'way')
  FROM (
    SELECT
      ST_AsMVTGeom(center, ST_TileEnvelope(z, x, y), extent => 4096, buffer => 64, clip_geom => true) AS way,
      id,
      ref,
      feature
    FROM level_crossings_grouped
    WHERE buffered && ST_TileEnvelope(z, x, y)
  ) as tile
  WHERE way IS NOT NULL
);

CREATE OR REPLACE FUNCTION level_crossings_grouped_buffered(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE SQL
  IMMUTABLE
  STRICT
  PARALLEL SAFE
RETURN (
  SELECT
    ST_AsMVT(tile, 'level_crossings_grouped_buffered', 4096, 'way')
  FROM (
    SELECT
      ST_AsMVTGeom(buffered, ST_TileEnvelope(z, x, y), extent => 4096, buffer => 64, clip_geom => true) AS way,
      id
    FROM level_crossings_grouped
    WHERE buffered && ST_TileEnvelope(z, x, y)
      AND count > 1
  ) as tile
  WHERE way IS NOT NULL
);
