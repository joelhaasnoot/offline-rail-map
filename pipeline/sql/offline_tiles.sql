-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Joel Haasnoot
--
-- Tile functions for offline packs, loaded after the upstream import (see build-country.sh).

-- railway_line_high for the app. From zoom 10 it is upstream's function. Below that, ways that
-- would be drawn the same are merged into one feature per tile: OSM splits a line into many short
-- ways wherever any tag changes, and at low zoom a tile would otherwise hold tens of thousands of
-- tiny features that phones must filter one by one for every style layer.
--
-- The grouping columns are the properties the app's style reads from railway_line_high below zoom
-- 10, in any view. Bridges and tunnels stay separate ways because the style only draws the long ones
-- (by way_length). Other columns are left out at these zooms; the style does not use them there.
-- The zoom filter repeats the one in upstream's railway_line_high (import/sql/tile_views.sql).
CREATE OR REPLACE FUNCTION railway_line_high_offline(z integer, x integer, y integer)
  RETURNS bytea
  LANGUAGE SQL
  IMMUTABLE
  STRICT
  PARALLEL SAFE
RETURN (
  CASE WHEN z >= 10 THEN railway_line_high(z, x, y) ELSE (
    SELECT
      ST_AsMVT(tile, 'railway_line_high', 4096, 'way')
    FROM (
      SELECT
        min(id) AS id,
        ST_AsMVTGeom(ST_LineMerge(ST_Collect(way)), ST_TileEnvelope(z, x, y), extent => 4096, buffer => 64, clip_geom => true) AS way,
        sum(way_length) AS way_length,
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
        route_count
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
        gauge1, gaugeint2, gauge2, loading_gauge, operator_color, primary_operator, route_count
      ORDER BY
        coalesce(layer, 0),
        rank NULLS LAST,
        maxspeed NULLS FIRST
    ) AS tile
    WHERE way IS NOT NULL
  ) END
);
