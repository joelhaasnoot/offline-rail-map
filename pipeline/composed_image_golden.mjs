#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Joel Haasnoot
//
// Writes reference layouts for the composed icons used in legend.json, computed by the website's own
// loadImages/layoutImages (proxy/js/ui.js), for ComposedImageTest in the Android app.
// Run after prepare_style.py when the upstream style or sprites change:
//   node pipeline/composed_image_golden.mjs

import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const uiJs = fs.readFileSync(path.join(root, 'pipeline/work/OpenRailwayMap-vector/proxy/js/ui.js'), 'utf8');
const assets = path.join(root, 'android/app/src/main/assets');
const outDir = path.join(root, 'android/app/src/test/resources/composed-image');

function extract(startPattern) {
  const start = uiJs.search(startPattern);
  const end = uiJs.indexOf('\n}\n', start);
  if (start < 0 || end < 0) {
    throw new Error(`${startPattern} not found in ui.js`);
  }
  return uiJs.slice(start, end + 3);
}

const upstream = new Function('map', `
  ${extract(/^const imageMatcher = /m)}
  ${extract(/^function layoutImages\(images\)/m)}
  return {loadImages, layoutImages};
`);

const legend = JSON.parse(fs.readFileSync(path.join(assets, 'style/legend.json'), 'utf8'));

fs.mkdirSync(outDir, {recursive: true});
for (const suffix of ['', '@2x']) {
  const sprite = JSON.parse(fs.readFileSync(path.join(assets, `sprites/symbols${suffix}.json`), 'utf8'));
  const map = {
    getImage: id => sprite[id] ? {data: {width: sprite[id].width, height: sprite[id].height}, pixelRatio: sprite[id].pixelRatio} : null,
  };
  const {loadImages, layoutImages} = upstream(map);

  const ids = new Set();
  (function walk(value, key) {
    if (Array.isArray(value)) {
      value.forEach(v => walk(v, key));
    } else if (value && typeof value === 'object') {
      Object.entries(value).filter(([k]) => k !== 'keys').forEach(([k, v]) => walk(v, k));
    } else if (typeof value === 'string' && key.startsWith('feature') && !sprite[value] && /[|@]/.test(value)) {
      ids.add(value);
    }
  })(legend, '');

  // id, width, height, then per image: x,y,sdfX,sdfY separated by ";"
  const lines = [...ids].sort().map(id => {
    const {width, height, images} = layoutImages(loadImages(id.split('|')));
    const placed = images.map(i => [i.offset.x, i.offset.y, i.sdfOffset.x, i.sdfOffset.y].join(',')).join(';');
    return [id, width, height, placed].join('\t');
  });
  fs.writeFileSync(path.join(outDir, `golden${suffix}.tsv`), lines.join('\n') + '\n');
  console.log(`golden${suffix}.tsv: ${lines.length} composed icons`);
}
