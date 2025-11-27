// Save as: js/ui.js
/**
 * UI Management Module
 *
 * This module handles all webpage manipulation including:
 * - Map initialization and management
 * - User interface controls
 * - Visual feedback and updates
 */

// DOM elements and map references

const elements = {
  map: L.map('map').setView([45, 12], 5),
  icaoInput: document.getElementById('icao'),
  latInput: document.getElementById('lat'),
  lonInput: document.getElementById('lon'),
  sizeInput: document.getElementById('size'),
  sdwnSelect: document.getElementById('sdwn-select'),
  overSelect: document.getElementById('over-mode'),
  radiusInput: document.getElementById('radius'),
  latlonContainer: document.getElementById('latlon-container'),
  icaoContainer: document.getElementById('icao-container'),
  btnGetCoords: document.getElementById('btn-get-coords'),
  btnConnect: document.getElementById('btn-connect'),
  fgfsPortInput: document.getElementById('fgfs-port'),
  flightPathControls: document.getElementById('flight-path-controls'),
  btnTogglePath: document.getElementById('btn-toggle-path'),
  btnSavePath: document.getElementById('btn-save-path'),
  btnSaveRoute: document.getElementById('btn-save-route'),
  btnClearPath: document.getElementById('btn-clear-path'),
  btnSelectFromMap: document.getElementById('btn-select-from-map'),
  controlsPanel: document.getElementById('controls'),
  resSvgContainer: document.getElementById('res-svg-container'),
  mapContainer: document.getElementById('map'),
  mapVisibilityFilters: document.getElementById('map-visibility-filters'),
  tilePreviewImage: document.getElementById('tilePreview'),
  downloadBtn: document.getElementById('downloadBtn'),
  opacitySlider: document.getElementById('opacity-slider'),
  btnDownloadAroundAircraft: document.getElementById('btn-download-around-aircraft'),
  btnFillHoles: document.getElementById('btn-fill-holes'),
  mapServerSelect: document.getElementById('map-server-select'),
  outputPathBox: document.getElementById('output-path-box'),
  backupPathBox: document.getElementById('backup-path-box'),
  btnSavePaths: document.getElementById('btn-save-paths'),
  directorySettingsHeader: document.getElementById('directory-settings-content').previousElementSibling,
  directorySettingsContent: document.getElementById('directory-settings-content'),
  routeDropZone: document.getElementById('route-drop-zone'),
  routeWaypointList: document.getElementById('route-waypoint-list'),
  routeSettingsHeader: document.getElementById('route-section-content').previousElementSibling,
  routeSettingsContent: document.getElementById('route-section-content'),
  dateFilterSlider: document.getElementById('date-filter-slider'),
  dateFilterLabel: document.getElementById('date-filter-label')
};

const CROSSHAIR_SVG_ICON_HTML = '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 32 32">' +
  '<g stroke="#000000" stroke-width="5" stroke-linecap="round">' +
  '<line x1="2" y1="16" x2="30" y2="16" /><line x1="16" y1="2" x2="16" y2="30" />' +
  '</g>' +
  '<g stroke="#FFFFFF" stroke-width="3" stroke-linecap="round">' +
  '<line x1="2" y1="16" x2="30" y2="16" /><line x1="16" y1="2" x2="16" y2="30" />' +
  '</g>' +
  '</svg>';

const AIRPLANE_SVG_ICON_HTML = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24">' +
  '<path fill="#333333" d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"/></svg>';

// Map layers and markers
let coverageLayer = L.layerGroup().addTo(elements.map);
let aircraftMarker = null;
let flightPathPolyline = null;
let flightPathMarkersLayer = L.layerGroup().addTo(elements.map);
let airportMarkers = L.layerGroup();

const AIRPORT_MARKER_CLASS = 'airport-marker';

const MARKER_SAMPLING_INTERVAL = 10;

const defaultMarkerStyle = {
  radius: 4,
  fillColor: "#ff7800", // Orange
  color: "#000",
  weight: 1,
  opacity: 1,
  fillOpacity: 0.8
};

const activatedMarkerStyle = {
  radius: 8, // Larger
  fillColor: "#007bff", // Blue
  color: "#fff",
  weight: 2,
  opacity: 1,
  fillOpacity: 1
};

const ICAO_SUGGESTION_ID = 'icao-suggestions-popup';
let currentSuggestionList = null;

const PATH_FOR_HELIPORT_H_CENTERED = 'M19 5v14H5V5h14zm-4 6H9V9h6v2zM9 15h6v-2H9v2z';

// ui.js — NEW VISIBILITY_CONFIG
const VISIBILITY_CONFIG = [
  {
    id: 'tiles',
    label: 'Tiles',
    svg: `
      <rect x="3" y="3" width="6" height="6" rx="1" />
      <rect x="10" y="3" width="6" height="6" rx="1" />
      <rect x="17" y="3" width="4" height="6" rx="1" />
      <rect x="3" y="10" width="6" height="6" rx="1" />
      <rect x="10" y="10" width="6" height="6" rx="1" />
      <rect x="17" y="10" width="4" height="6" rx="1" />
      <rect x="3" y="17" width="6" height="4" rx="1" />
      <rect x="10" y="17" width="6" height="4" rx="1" />
      <rect x="17" y="17" width="4" height="4" rx="1" />
    `
  },
  {
    id: 'airports',
    label: 'Airports',
    svg: `
  <path d="M12 2 v8" />
  <path d="M4 10 l8 3 8-3" />
  <path d="M9 22 l3-6 3 6" />
  <path d="M3 13 l6 1 M21 13 l-6 1" />
    `
  },
  {
    id: 'minorAirports',
    label: 'Minor AP',
    svg: `
      <rect x="5" y="10" width="14" height="4" rx="1"/>
      <line x1="7" y1="12" x2="17" y2="12"/>
      <circle cx="12" cy="12" r="1.6" />
    `
  },
  {
    id: 'heliports',
    label: 'Heliports',
    svg: `
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <path d="M9 16 v-8 M15 16 v-8 M9 12 h6" />
    `
  },
  {
    id: 'navaids',
    label: 'Navaids',
    svg: `
    <circle cx="12" cy="12" r="1.6"/>
    <circle cx="12" cy="12" r="5" fill="none"/>
    <circle cx="12" cy="12" r="8" fill="none"/>
  `
  },
  {
    id: 'route',
    label: 'Route',
    svg: `
      <circle cx="5" cy="18" r="2"/>
      <circle cx="12" cy="10" r="2"/>
      <circle cx="19" cy="6" r="2"/>
      <path d="M5 18 Q 8 12, 12 10 T 19 6" fill="none"/>
    `
  }
];


/**
 * Renders visibility buttons based on state.
 * @param {Object} visibilityState - Filter state.
 * @param {Function} clickCallback - Function to call on click.
 */
function renderVisibilityFilters(visibilityState, clickCallback) {
  const container = elements.mapVisibilityFilters;
  if (!container) return;

  container.innerHTML = '';

  VISIBILITY_CONFIG.forEach(item => {
    const isActive = visibilityState[item.id];
    const button = document.createElement('button');
    button.id = `filter-${item.id}`;
    button.classList.add('filter-button', isActive ? 'active' : 'inactive');
    button.title = `${item.label} (Click to toggle)`;
    button.dataset.filter = item.id;

    // Create SVG for icon
    button.innerHTML = item.svg
      ? `<svg class="filter-icon" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"
                role="img" aria-label="${item.label}">
                <g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                ${item.svg}
                </g>
            </svg>`
      : `<svg class="filter-icon" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"
                role="img" aria-label="${item.label}">
                <path d="${item.icon}" fill="none" stroke="currentColor" stroke-width="2"
                    stroke-linecap="round" stroke-linejoin="round"/>
            </svg>`;

    button.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    button.setAttribute('aria-label', `${item.label} layer`);

    button.addEventListener('click', () => clickCallback(item.id));
    container.appendChild(button);
  });
}


/**
 * Initializes the base map with OpenStreetMap tiles
 */

/**
 * Updates map coverage display with filtered tiles
 * @param {Array} coverageData - Tile coverage information
 * @param {Set} allowedResolutions - Set of allowed resolution IDs
 * @param {number} currentOpacity - Current opacity setting
 * @param {number} dateFilterIndex - The index for the date filter
 * @param {Date} sessionStartTime - The start time of the current session
 * @param {number} lowDetailThreshold - The detail score threshold for marking tiles
 */
function updateMapCoverage(coverageData, allowedResolutions, currentOpacity, dateFilterIndex, sessionStartTime, lowDetailThreshold) {
  coverageLayer.clearLayers();
  const now = new Date();

  coverageData.forEach(tile => {
    // --- TIME FILTER LOGIC ---
    if (dateFilterIndex !== 6) {
      if (!tile.last_modified || typeof tile.last_modified !== 'string') {
        return;
      }
      const tileDate = new Date(tile.last_modified.replace(' ', 'T'));
      let showTile = false;

      switch (dateFilterIndex) {
        case 0:
          if (sessionStartTime) showTile = tileDate >= sessionStartTime;
          break;
        case 1:
          showTile = (now - tileDate) < (24 * 3600 * 1000);
          break;
        case 2:
          const today = new Date();
          const startOfToday = new Date(today.getFullYear(), today.getMonth(), today.getDate());
          const startOfYesterday = new Date(startOfToday);
          startOfYesterday.setDate(startOfYesterday.getDate() - 1);
          showTile = tileDate >= startOfYesterday && tileDate < startOfToday;
          break;
        case 3:
          showTile = (now - tileDate) < (7 * 24 * 3600 * 1000);
          break;
        case 4:
          showTile = (now - tileDate) < (30 * 24 * 3600 * 1000);
          break;
        case 5:
          showTile = (now - tileDate) < (365 * 24 * 3600 * 1000);
          break;
      }
      if (!showTile) {
        return;
      }
    }

    if (!allowedResolutions.has(tile.sizeId)) return;

    // Draw tile on map
    const popupHtml = `ID: ${tile.id}<br>Resolution: ${tile.sizeId}<br><b>Score: ${tile.detail_score.toFixed(3)}</b><br><button class="preview-button" data-tile-id="${tile.id}" data-size-id="${tile.sizeId}">View Preview</button>`;
    const bounds = [[tile.bbox.latLL, tile.bbox.lonLL], [tile.bbox.latUR, tile.bbox.lonUR]];
    L.rectangle(bounds, { ...getStyleForSizeId(tile.sizeId), fillOpacity: currentOpacity, opacity: 1 }).addTo(coverageLayer).bindPopup(popupHtml);

    // Now the variable "lowDetailThreshold" will exist and this check will work
    if (tile.detail_score !== -1.0 && tile.detail_score < lowDetailThreshold) {
      const centerLat = (tile.bbox.latLL + tile.bbox.latUR) / 2;
      const centerLon = (tile.bbox.lonLL + tile.bbox.lonUR) / 2;
      const point1 = L.latLng(centerLat, tile.bbox.lonLL);
      const point2 = L.latLng(centerLat, tile.bbox.lonUR);
      const widthInMeters = point1.distanceTo(point2);
      const dotRadius = widthInMeters * 0.05;

      L.circle([centerLat, centerLon], {
        radius: dotRadius,
        color: 'black',
        fillColor: 'black',
        fillOpacity: 0.7,
        weight: 1,
        interactive: false
      }).addTo(coverageLayer);
    }
  });
}

/**
 * Updates aircraft position marker on the map
 * @param {Object} data - Aircraft status data
 */
function updateAircraftPosition(data) {
  updateFgfsIndicator(data.active);

  // debug data from aircraft
  /**
  console.log('updateAircraftPosition -> data', data);
  console.log('isConnected:', window.main?.state?.isConnected,
              'heading:', window.main?.state?.currentHeading,
              'allowed:', window.main?.state?.daaAllowed);
  **/

  if (!data.active) {
    if (aircraftMarker) elements.map.removeLayer(aircraftMarker);
    aircraftMarker = null;
    return;
  }

  const latLng = [data.lat, data.lon];
  const tooltipContent = `
    <b>Heading:</b> ${Math.round(data.heading)}°<br>
    <b>Altitude:</b> ${Math.round(data.altitude)} ft<br>
    <b>Speed:</b> ${Math.round(data.speed)} kts
    `;

  if (!aircraftMarker) {
    const aircraftSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="28" height="28">
        <path d="M21 16v-2l-8-5V3.5c0-.83-.67-1.5-1.5-1.5S10 2.67 10 3.5V9l-8 5v2l8-2.5V19l-2 1.5V22l3.5-1 3.5 1v-1.5L13 19v-5.5l8 2.5z"
        fill="#d9534f" stroke="black" stroke-width="1"/>
        </svg>`;

    const icon = L.divIcon({
      html: aircraftSVG,
      className: 'aircraft-icon',
      iconSize: [28, 28],
      iconAnchor: [14, 14]
    });

    aircraftMarker = L.marker(latLng, {
      icon: icon,
      rotationAngle: data.heading
    })
      .addTo(elements.map)
      .bindTooltip(tooltipContent);
  } else {
    aircraftMarker.setLatLng(latLng);
    aircraftMarker.setRotationAngle(data.heading);
    aircraftMarker.setTooltipContent(tooltipContent);
  }
}


/**
 * Draws a confirmed green job circle on the map.
 * @param {string} jobId - Unique job identifier
 * @param {number} lat - Latitude coordinate
 * @param {number} lon - Longitude coordinate
 * @param {number} radiusNm - Circle radius in nautical miles
 * @param {Object} activeCircles - The registry of active circles to update
 */
function drawCircle(jobId, lat, lon, radiusNm, activeCircles) {
  if (activeCircles[jobId]) return;

  const circle = L.circle([lat, lon], {
    radius: radiusNm * 1852, // Convert NM to meters
    color: '#00cc00',
    fillColor: '#00cc00',
    fillOpacity: 0.15,
    weight: 1.5
  }).addTo(elements.map);

  activeCircles[jobId] = circle;
}

/**
 * Populates the downscaling dropdown based on current size selection
 */
function populateSdwnDropdown() {
  const maxSize = parseInt(elements.sizeInput.value, 10);
  const currentSdwnValue = elements.sdwnSelect.value;

  elements.sdwnSelect.innerHTML = '';
  elements.sdwnSelect.add(new Option("Disabled", "-1"));

  for (let i = 0; i <= maxSize; i++) {
    elements.sdwnSelect.add(new Option(`From ${maxSize} to ${i}`, i));
  }

  elements.sdwnSelect.value = (currentSdwnValue >= 0 && currentSdwnValue <= maxSize) ? currentSdwnValue : "-1";
}

/**
 * Updates UI elements based on FlightGear connection state
 * @param {boolean} isConnected - Current connection status
 */
function updateFgfsIndicator(status) {
  const btn = elements.btnConnect;
  // Removes all previous state classes for clean management
  btn.classList.remove('active', 'connecting', 'disconnected');

  // --- NEW CONTROL LOGIC ---
  // Handles both boolean 'true' and string 'connected' as active state.
  if (status === 'connected' || status === true) {
    btn.classList.add('active');
    btn.textContent = 'FGFS On';
  } else {
    // HIDE flight path buttons
    if (status === 'connecting') {
      btn.classList.add('connecting');
      btn.textContent = 'Wait...';
    } else { // disconnected o false
      btn.classList.add('disconnected');
      btn.textContent = 'FGFS Off';
    }
  }
}

/**
 * Renders resolution filter buttons as SVG elements
 * @param {Array} resState - Array of resolution states (active/inactive)
 * @param {Function} clickCallback - Handler for button clicks
 */
function renderSvgButtons(resState, clickCallback) {
  elements.resSvgContainer.innerHTML = '';

  resState.forEach((isActive, index) => {
    const div = document.createElement('div');
    div.classList.add('res-svg-button');
    div.innerHTML = createSvgCircle(index, isActive);
    div.addEventListener('click', () => clickCallback(index));
    elements.resSvgContainer.appendChild(div);
  });
}

/**
 * Populates the map server dropdown selector with options from the server.
 * @param {Array<Object>} servers - An array of server objects, each with id and name.
 */
function populateMapServerSelector(servers) {
  const select = elements.mapServerSelect;
  select.innerHTML = ''; // Clears existing options

  servers.forEach(server => {
    const option = document.createElement('option');
    option.value = server.id;
    option.textContent = `${server.id}: ${server.name}`;
    select.appendChild(option);
  });
}

/**
 * Draws the waypoint list in the route tray.
 * @param {Array<Object>} waypoints - The array of waypoints.
 * @param {string} fileName - The name of the loaded file.
 */
export function renderWaypointList(waypoints, fileName) {
  const listContainer = elements.routeWaypointList;
  if (!listContainer) return;

  if (!Array.isArray(waypoints) || waypoints.length === 0) {
    listContainer.innerHTML = '';
    return;
  }

  // Get distance calculation function exposed by route.js
  const computeLegDistancesNM =
    (window.computeLegDistancesNM) ||
    (window.route && window.route.computeLegDistancesNM);

  const legs = computeLegDistancesNM
    ? computeLegDistancesNM(waypoints)
    : waypoints.map((_, i) => (i === 0 ? 0 : NaN));

  let html = '';
  if (fileName) html += `<strong>${fileName}</strong>`;
  html += `<ul class="route-wp-list">`;

  waypoints.forEach((wp, idx) => {
    // Type: use what comes from addWaypointManual, otherwise try to deduce
    const rawType =
      wp.type ||
      wp.kind ||
      (wp.source === 'airport' ? 'Airport' :
        wp.source === 'navaid' ? 'Navaid' :
          '');

    const typeLabel = rawType ? String(rawType) : '';

    // Leg distance from previous waypoint (in NM)
    const legNm = (typeof legs[idx] === 'number' && isFinite(legs[idx]))
      ? legs[idx].toFixed(1)
      : (idx === 0 ? '0.0' : '—');

    // Meta row: type + leg if available
    let metaHtml = '';
    const pieces = [];
    if (typeLabel) pieces.push(typeLabel);
    if (legNm !== '—') pieces.push(`${legNm}&nbsp;nm`);
    if (pieces.length) {
      metaHtml = `<div class="wp-meta">${pieces.join(' • ')}</div>`;
    }

    html += `
    <li class="wp-status-${wp.status}" data-index="${idx}">
    <div class="wp-main">
    <div class="wp-name">${wp.name}</div>
    ${metaHtml}
    </div>
    <button class="wp-del" title="Remove waypoint" data-index="${idx}">🗑️</button>
    </li>`;
  });

  html += `</ul>`;
  listContainer.innerHTML = html;

  const ul = listContainer.querySelector('ul.route-wp-list');
  if (!ul) return;

  // Click on trash → remove waypoint
  ul.addEventListener('click', (ev) => {
    const btn = ev.target.closest('button.wp-del');
    if (!btn) return;
    const i = parseInt(btn.dataset.index, 10);
    if (!Number.isNaN(i)) {
      (window.removeWaypointAt || window.route?.removeWaypointAt)?.(i);
    }
  });

  // Row hover → highlight point (red ring) + row bg
  ul.addEventListener('mouseover', (ev) => {
    const li = ev.target.closest('li[data-index]');
    if (!li) return;
    const i = parseInt(li.dataset.index, 10);
    li.classList.add('wp-hover');
    (window.highlightWaypoint || window.route?.highlightWaypoint)?.(i, true);
  });

  ul.addEventListener('mouseout', (ev) => {
    const li = ev.target.closest('li[data-index]');
    if (!li) return;
    const i = parseInt(li.dataset.index, 10);
    li.classList.remove('wp-hover');
    (window.highlightWaypoint || window.route?.highlightWaypoint)?.(i, false);
  });

  try {
    listContainer.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  } catch { }
}


/**
 * Toggles map coordinate selection mode
 * @param {boolean} isSelectionMode - Whether selection mode should be active
 */
function toggleMapSelectionMode(isSelectionMode) {
  const btn = elements.btnSelectFromMap;

  if (isSelectionMode) {
    // --- STATE: Map Selection is ACTIVE ---
    btn.classList.add('active');
    // Use the SVG icon instead of the text symbol
    btn.innerHTML = CROSSHAIR_SVG_ICON_HTML;
    btn.title = 'Return to ICAO/Manual Input';

    elements.mapContainer.classList.add('map-selection-active');

    elements.latlonContainer.style.display = 'block';
    elements.icaoInput.disabled = true;
    elements.latInput.disabled = true;
    elements.lonInput.disabled = true;
  } else {
    // --- STATE: ICAO/Manual is ACTIVE ---
    btn.classList.remove('active');
    // Use the new airplane SVG constant
    btn.innerHTML = AIRPLANE_SVG_ICON_HTML;
    btn.title = 'Select Coordinates from Map';

    elements.mapContainer.classList.remove('map-selection-active');

    elements.latlonContainer.style.display = 'none';
    elements.icaoInput.disabled = false;
    elements.latInput.disabled = false;
    elements.lonInput.disabled = false;
  }
}

/**
 * Shows ICAO input mode and hides coordinate inputs
 */
function showIcaoMode() {
  elements.latlonContainer.style.display = 'none';
  elements.btnGetCoords.style.display = 'none';
}

/**
 * Displays tile preview in the preview panel
 * @param {string} tileId - Tile identifier
 * @param {number} sizeId - Resolution identifier
 * @param {string} imageUrl - Preview image URL
 */
function showTileInPanel(tileId, sizeId, previewUrl, nativeUrl) {
  elements.tilePreviewImage.src = previewUrl;
  elements.tilePreviewImage.style.display = 'block';

  elements.downloadBtn.textContent = `Download full PNG (Res: ${sizeId})`;
  elements.downloadBtn.style.display = 'block';

  elements.downloadBtn.onclick = () => {
    const a = document.createElement('a');
    a.href = nativeUrl; // full resolution
    a.download = `${tileId}_full.png`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  };
}

/**
 * Creates a draggable preview circle on the map and returns it.
 * @param {number} lat - Latitude coordinate
 * @param {number} lon - Longitude coordinate
 * @param {number} radiusNm - Radius in nautical miles
 * @returns {L.Circle} The Leaflet circle object
 */
function previewArea(lat, lon, radiusNm) {
  const previewCircle = L.circle([lat, lon], {
    radius: radiusNm * 1852,
    color: '#ff7800',
    fillColor: '#ff7800',
    fillOpacity: 0.2,
    weight: 2,
    dashArray: '5, 5'
  }).addTo(elements.map);

  // Enable Geoman editing
  previewCircle.pm.enable({
    allowSelfIntersection: false,
    draggable: true
  });

  // Defer the style update to the next event loop cycle.
  // This ensures that Geoman has finished creating the handle markers
  // in the DOM before we try to style them.
  setTimeout(() => {
    updateHandleStyles(previewCircle);
  }, 0);

  return previewCircle;
}

/**
 * Creates a custom L.DivIcon for Geoman handles.
 * @param {number} size - The size of the icon in pixels.
 * @returns {L.DivIcon} A Leaflet DivIcon instance.
 */
function createCustomHandleIcon(size) {
  return L.divIcon({
    className: 'custom-pm-handle',
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2]
  });
}

/**
 * Updates the size and style of a circle's editing handles.
 * The handle size is based on the circle's radius in nautical miles.
 * @param {L.Circle} circle - The Leaflet circle layer.
 */
function updateHandleStyles(circle) {
  // ...your existing code to determine handleSize...
  if (!circle || !circle.pm || !circle.pm.enabled()) {
    return;
  }
  const radiusNm = parseFloat(elements.radiusInput.value) || 0;
  let handleSize;
  handleSize = radiusNm * 0.3 + 18;
  /*
  if (radiusNm > 60) {
      handleSize = 28;
  } else if (radiusNm > 25) {
      handleSize = 22;
  } else {
      handleSize = 18;
  }
  */
  const newIcon = createCustomHandleIcon(handleSize);

  const markers = circle.pm._markers;
  if (markers) {
    markers.forEach(marker => {
      marker.setIcon(newIcon);
    });
  }
}


/**
 * Removes the preview circle from the map
 */

// Internal helper functions
function getStyleForSizeId(sizeId) {
  const colors = ['#0000FF', '#2A00D5', '#5500AA', '#800080', '#AA0055', '#D5002A', '#FF0000'];
  return {
    color: colors[sizeId] || '#333',
    weight: 1,
    fillColor: colors[sizeId] || '#333'
  };
}

function createSvgCircle(index, selected) {
  const fillColor = selected ? '#0088cc' : 'white';
  const strokeColor = '#0088cc';
  const textColor = selected ? 'white' : '#0088cc';
  return `
    <svg viewBox="0 0 32 32">
    <circle cx="16" cy="16" r="14" fill="${fillColor}" stroke="${strokeColor}" stroke-width="2"/>
    <text x="16" y="21" text-anchor="middle" fill="${textColor}" font-size="16">${index}</text>
    </svg>`;
}

/**
 * Generates SVG for ICAO symbol.
 * Symbols are drawn on a 32x32 viewBox for easy centering.
 * @param {string} type - Navaid Type (e.g. 'VOR', 'NDB', 'DME', 'VORTAC').
 * @returns {string} SVG code as string.
 */
/**
 * Generates SVG for an ICAO navaid symbol.
 * Drawing on 32x32 viewBox for easy centering.
 * @param {string} type - 'VOR', 'DME', 'NDB', 'VOR/DME', 'VORTAC', 'TACAN'
 * @param {object} [opts]
 * @param {number} [opts.size=32] - size in px (width/height)
 * @param {string} [opts.stroke='currentColor'] - line color
 * @param {number} [opts.strokeWidth=1.8] - line thickness (in viewBox units)
 * @param {boolean} [opts.centerDot=true] - draw center dot
 * @param {boolean} [opts.nonScalingStroke=false] - keeps stroke constant with scaling
 * @returns {string} SVG as string
 */
function createIcaoNavaidSvg(type, opts = {}) {
  const {
    size = 32,
    stroke = 'currentColor',
    strokeWidth = 1.8,
    centerDot = true,
    nonScalingStroke = false
  } = opts;

  const type_uc = String(type).toUpperCase();
  const viewBox = '0 0 32 32';
  const vef = nonScalingStroke ? 'vector-effect="non-scaling-stroke"' : '';

  // "Standard" 32x32 centered hexagon
  const HEX = 'M16 4 L27 10 L27 22 L16 28 L5 22 L5 10 Z';
  // DME Square
  const SQR = 'M8 8 L24 8 L24 24 L8 24 Z';

  let content = '';

  // --- VOR / VOR+DME / VORTAC ---
  if (type_uc.includes('VOR')) {
    content += `<path d="${HEX}" fill="none" stroke="${stroke}" stroke-width="${strokeWidth}" ${vef}/>`;
    if (type_uc.includes('DME')) {
      // VOR/DME = hexagon + box
      content += `<path d="${SQR}" fill="none" stroke="${stroke}" stroke-width="${strokeWidth}" ${vef}/>`;
    }
    if (type_uc.includes('TACAN') || type_uc.includes('VORTAC')) {
      // VORTAC = hexagon + three black "notches"
      // positioned on top-left, top-right and bottom-center
      content += [
        // top-left
        `<path d="M11 8 L14 10 L12 13 L9 11 Z" fill="black"/>`,
        // top-right
        `<path d="M21 8 L23 11 L20 13 L18 10 Z" fill="black"/>`,
        // bottom-center
        `<path d="M14.5 22 L17.5 22 L17.5 26 L14.5 26 Z" fill="black"/>`
      ].join('');
    }

    // --- TACAN "Y" with black lobes ---
  } else if (type_uc.includes('TACAN')) {
    // "truncated" hexagon type outline (ICAO look)
    const OUTER = 'M16 4 L26 10 L26 20 L19 28 L13 28 L6 20 L6 10 Z';
    // three black lobes
    content += [
      `<path d="M16 16 L25.5 10 L25.5 20 Z" fill="black"/>`,
      `<path d="M16 16 L6.5 10 L6.5 20 Z" fill="black"/>`,
      `<path d="M9 22 L16 16 L23 22 L16 29 Z" fill="black"/>`,
      // central white "hole" for ICAO aspect
      `<circle cx="16" cy="16" r="6" fill="white"/>`,
      `<path d="${OUTER}" fill="none" stroke="${stroke}" stroke-width="${strokeWidth}" ${vef}/>`
    ].join('');

    // --- DME: square ---
  } else if (type_uc.includes('DME')) {
    content += `<path d="${SQR}" fill="none" stroke="${stroke}" stroke-width="${strokeWidth}" ${vef}/>`;

    // --- NDB: dotted ring ---
  } else if (type_uc.includes('NDB')) {
    // dotted ring: dash almost zero + constant gap + round caps
    // (scales well; adjust gap if you want more/less dots)
    const ringStroke = stroke; // stesso colore
    const ringWidth = strokeWidth;
    const gap = 3.2; // distance between "dots"
    content += `<circle cx="16" cy="16" r="10.5" fill="none" stroke="${ringStroke}" stroke-width="${ringWidth}" stroke-dasharray="0.1 ${gap}" stroke-linecap="round" ${vef}/>`;
  }

  // puntino centrale (quasi tutti i simboli lo hanno)
  if (centerDot) content += `<circle cx="16" cy="16" r="2.5" fill="black"/>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${type_uc} navaid" width="${size}" height="${size}" viewBox="${viewBox}">${content}</svg>`;
}

function initializeMap() {
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
  }).addTo(elements.map);
  elements.map.createPane('flightPathPane');
  elements.map.getPane('flightPathPane').style.zIndex = 450;
}

// Layer Group per tenere traccia dei marker Navaid

// La dimensione del viewBox (32x32) determina l'iconSize
const NAVAID_ICON_SIZE = 32;

function getNavaidIcon(type) {
  // Chiama la nuova funzione SVG con opzioni appropriate
  const svgHtml = createIcaoNavaidSvg(type, {
    size: NAVAID_ICON_SIZE,
    stroke: 'black',
    strokeWidth: 2, // Aumentiamo leggermente per visibilità sulla mappa
    nonScalingStroke: true
  });

  return L.divIcon({
    html: svgHtml,
    className: 'navaid-icon-container', // Useremo questa classe solo per il contenitore
    iconSize: [NAVAID_ICON_SIZE, NAVAID_ICON_SIZE],
    iconAnchor: [NAVAID_ICON_SIZE / 2, NAVAID_ICON_SIZE / 2], // **Centra l'icona**
    popupAnchor: [0, -10]
  });
}

/**
 * Collects job parameters from UI inputs
 * @returns {Object} Contains all parameters needed to start a job
 */
function getJobParameters() {
  const jobParams = {
    radius: parseFloat(elements.radiusInput.value) || 3,
    size: parseInt(elements.sizeInput.value, 10) || 4,
    over: parseInt(elements.overSelect.value, 10) || 1,
    sdwn: parseInt(elements.sdwnSelect.value, 10)  // può restituire -1
  };

  // Se lat/lon non sono compilati, usa ICAO
  if (elements.latlonContainer.style.display === 'block' &&
    elements.latInput.value &&
    elements.lonInput.value) {
    jobParams.lat = parseFloat(elements.latInput.value);
    jobParams.lon = parseFloat(elements.lonInput.value);
  } else {
    jobParams.icao = elements.icaoInput.value.trim();
  }

  // Mai null/undefined
  Object.keys(jobParams).forEach(k => {
    if (jobParams[k] == null || Number.isNaN(jobParams[k])) {
      jobParams[k] = (k === 'sdwn') ? -1 : 3; // default sicuro
    }
  });

  return jobParams;
}

function clearPreview() {
  if (window.pendingCircle) {
    elements.map.removeLayer(window.pendingCircle);
    window.pendingCircle = null;
  }
}

function setupInteractiveSelection() {
  // Update preview when parameters change
  // Clear preview when switching to ICAO mode
  elements.icaoInput.addEventListener('input', () => {
    if (elements.icaoInput.value && window.pendingCircle) {
      clearPreview();
    }
  });

  function updatePreview() {
    if (elements.latInput.value && elements.lonInput.value && elements.radiusInput.value) {
      previewArea(
        parseFloat(elements.latInput.value),
        parseFloat(elements.lonInput.value),
        parseFloat(elements.radiusInput.value)
      );
    }
  }
}

function linkRadiusHandleToInput(circle) {
  // Update the input field's text value continuously for live feedback.
  circle.on('pm:markerdrag', e => {
    const nm = (circle.getRadius() / 1852).toFixed(1);
    elements.radiusInput.value = nm;
  });

  // Update the handle's visual style only ONCE at the end of the drag.
  circle.on('pm:markerdragend', e => {
    updateHandleStyles(circle);
  });
}


/**
 * Funzione interna per disegnare solo la linea continua del percorso.
 * @param {Array<Object>} flightPath - L'array dei punti del percorso.
 * @param {boolean} isVisible - Se la linea deve essere visibile.
 */
function updateFlightPathPolyline(flightPath, isVisible) {
  if (!isVisible) {
    if (flightPathPolyline) elements.map.removeLayer(flightPathPolyline);
    return;
  }
  if (flightPath && flightPath.length >= 2) {
    const latLngs = flightPath.map(p => [p.lat, p.lon]);
    if (flightPathPolyline) {
      flightPathPolyline.setLatLngs(latLngs);
      if (!elements.map.hasLayer(flightPathPolyline)) {
        flightPathPolyline.addTo(elements.map);
      }
    } else {
      flightPathPolyline = L.polyline(latLngs, { color: '#ff00ff', weight: 3, opacity: 0.7 }).addTo(elements.map);
    }
  } else {
    if (flightPathPolyline) {
      elements.map.removeLayer(flightPathPolyline);
      flightPathPolyline = null;
    }
  }
}

/**
 * NUOVA FUNZIONE: Disegna i punti interattivi campionando il percorso di volo.
 * @param {Array<Object>} flightPath - L'array dei punti del percorso.
 * @param {boolean} isVisible - Se i punti devono essere visibili.
 */
function updateFlightPathMarkers(flightPath, isVisible) {
  flightPathMarkersLayer.clearLayers(); // Pulisce i punti precedenti

  if (!isVisible || !flightPath || flightPath.length < 2) {
    return;
  }

  // Itera sul percorso, prendendo un punto ogni MARKER_SAMPLING_INTERVAL
  for (let i = 0; i < flightPath.length; i += MARKER_SAMPLING_INTERVAL) {
    const point = flightPath[i];

    // Determina lo stile in base allo stato 'isActivated' del punto
    const style = point.isActivated ? activatedMarkerStyle : defaultMarkerStyle;

    const marker = L.circleMarker([point.lat, point.lon], { ...style, pane: 'flightPathPane' })
      .addTo(flightPathMarkersLayer);

    // Aggiungi l'evento click
    marker.on('click', () => {
      // 1. Inverti lo stato del punto nei dati originali
      point.isActivated = !point.isActivated;

      // 2. Aggiorna lo stile del marker cliccato
      marker.setStyle(point.isActivated ? activatedMarkerStyle : defaultMarkerStyle);

      // 3. Qui puoi aggiungere logica futura. Esempio:
      console.log(`Punto del percorso a [${point.lat.toFixed(4)}, ${point.lon.toFixed(4)}] ${point.isActivated ? 'attivato' : 'disattivato'}.`);
    });

    marker.bindTooltip(`Alt: ${Math.round(point.altitude_ft)} ft<br>Speed: ${Math.round(point.speed_kts)} kts`);
  }
}

/**
 * Gestisce il rendering di tutto il percorso di volo.
 * @param {Array<Object>} flightPath - L'array dei punti del percorso.
 * @param {boolean} isVisible - Se il percorso deve essere visibile.
 * @param {boolean} isRouteFilterActive - NUOVO: Stato del filtro 'route'.
 */
function renderFlightPath(flightPath, isVisible) {
  // ⚠️ ASSUMIAMO che 'state.visibilityFilters.route' sia letto dal modulo 'main.js'
  //    e passato qui o che 'main.js' gestisca il layer.

  // Siccome 'main.js' chiama renderFlightPath da dentro la sua logica:
  const routeFilterActive = window.main?.state?.visibilityFilters?.route ?? true;

  // Se il filtro generale è OFF, la rotta è nascosta
  if (!routeFilterActive) {
    updateFlightPathPolyline(flightPath, false);
    updateFlightPathMarkers(flightPath, false);
    return;
  }

  // Se il filtro generale è ON, usiamo lo stato 'isVisible' (Hide/Show Path)
  updateFlightPathPolyline(flightPath, isVisible);
  updateFlightPathMarkers(flightPath, isVisible);
}


// === SEARCH MARKER + CIRCLE (minimal) ===
export let searchLayer = null;
export let searchMarker = null;
export let searchCircle = null;

export function clearSearchGraphics() {
  if (searchLayer && elements?.map) {
    elements.map.removeLayer(searchLayer);
  }
  searchLayer = null;
  searchMarker = null;
  searchCircle = null;
}

export function showSearchMarker(lat, lon) {
  const map = elements.map;
  if (!map) throw new Error('Map non inizializzata');

  // rimuovi eventuale marker precedente
  if (window._searchMarker) {
    try { map.removeLayer(window._searchMarker); } catch (_) { }
    window._searchMarker = null;
  }

  const m = L.marker([lat, lon], {
    draggable: false,
    title: 'Clicca per creare l’area'
  }).addTo(map);
  window._searchMarker = m;

  // (FIX) NON usare variabili inesistenti qui: niente `a.icao`
  // Se sei in Create Route, aggiungi un WP generico (l'ICAO lo gestisce onSelect)
  try {
    if (window.isManualRouteMode && window.isManualRouteMode()) {
      if (typeof window.addWaypointManual === 'function') {
        window.addWaypointManual({ name: 'SEARCH', lat, lon, source: 'icao' });
      }
    }
  } catch { }

  return m; // importante: ci serve in main.js per agganciare il click
}


export function removeSearchMarker() {
  const map = elements.map;
  if (window._searchMarker && map) {
    try { map.removeLayer(window._searchMarker); } catch (_) { }
    window._searchMarker = null;
  }
}

/** Crea/aggiorna/rimuove il cerchio leggendo il raggio dalla UI (in NM). */
export function toggleSearchCircleFromInputs(lat, lon) {
  const nm = Math.max(1, parseFloat(elements.radiusInput.value) || 10);
  const radiusMeters = nm * 1852;

  // crea (se non c'è), oppure aggiorna, oppure se tieni premuto CTRL lo rimuovi
  if (!searchCircle) {
    searchCircle = L.circle([lat, lon], {
      radius: radiusMeters,
      color: '#00cc00',
      fillColor: '#00cc00',
      fillOpacity: 0.15,
      weight: 1.5
    }).addTo(searchLayer);
  } else {
    // se il cerchio esiste già, aggiorna raggio e posizione
    searchCircle.setLatLng([lat, lon]);
    searchCircle.setRadius(radiusMeters);
  }
}


/**
 * Crea la struttura <ul> per la popup, la posiziona sotto l'input ICAO
 * e la aggiunge al DOM.
 */
function createSuggestionList(icaoInput) {
  if (currentSuggestionList) {
    currentSuggestionList.remove();
  }

  // 1. Crea la lista
  const ul = document.createElement('ul');
  ul.id = ICAO_SUGGESTION_ID;
  ul.classList.add('suggest'); // Riutilizzo la classe CSS del modale di rotta

  // 2. Aggiungi stili per posizionamento assoluto
  ul.style.position = 'absolute';
  ul.style.zIndex = '1000';
  ul.style.width = `${icaoInput.offsetWidth}px`;

  // 3. Posiziona sotto l'input
  const rect = icaoInput.getBoundingClientRect();
  ul.style.top = `${rect.bottom + window.scrollY}px`;
  ul.style.left = `${rect.left + window.scrollX}px`;

  document.body.appendChild(ul);
  currentSuggestionList = ul;
  return ul;
}

/**
 * Popola e mostra la popup con risultati ricchi.
 * @param {Array<Object>} items - Risultati della ricerca arricchiti da API.
 * @param {Object} icaoInput - Elemento DOM dell'input ICAO.
 * @param {Function} onSelect - Callback da chiamare alla selezione.
 */
function showIcaoSuggestions(items, icaoInput, onSelect) {
  if (!items || items.length === 0) {
    hideIcaoSuggestions();
    return;
  }

  const ul = createSuggestionList(icaoInput);
  ul.innerHTML = items.map(a => {
    const city = a.municipality ? ` (${a.municipality})` : '';
    const iata = a.iata_code ? ` ${a.iata_code}` : '';
    // Includi tutti i dati utili nell'attributo data-airport
    const data = JSON.stringify({ icao: a.icao, lat: a.lat, lon: a.lon, name: a.name });

    return `<li data-airport='${data}'><b>${a.icao}</b>${iata} — ${a.name}${city}</li>`;
  }).join('');

  ul.onclick = (ev) => {
    const li = ev.target.closest('li');
    if (!li) return;

    const airportData = JSON.parse(li.dataset.airport);
    onSelect(airportData);
    hideIcaoSuggestions();
  };
}

/**
 * Rimuove la lista di suggerimenti dal DOM.
 */
function hideIcaoSuggestions() {
  if (currentSuggestionList) {
    currentSuggestionList.remove();
    currentSuggestionList = null;
  }
}


/**
 * Navaid
 */

// Funzione principale per disegnare
let navaidMarkers = L.layerGroup();

/**
 * Disegna i navaids sulla mappa.
 * @param {Array<Object>} navaids    - Oggetti navaid dal backend
 * @param {L.Map}         mapInstance
 */
function drawNavaids(navaids, mapInstance) {
  // Svuota sempre il layer prima di ridisegnare
  navaidMarkers.clearLayers();

  if (!Array.isArray(navaids) || navaids.length === 0) {
    if (mapInstance.hasLayer(navaidMarkers)) mapInstance.removeLayer(navaidMarkers);
    return;
  }

  // util per formattare frequenze
  const fmt = {
    mhz: v => (isFinite(v) ? `${(+v).toFixed(2)} MHz` : 'N/D'),
    khzToMhz: v => (isFinite(v) ? `${(+v / 1000).toFixed(2)} MHz` : 'N/D')
  };

  navaids.forEach(n => {
    const lat = Number(n.lat), lon = Number(n.lon);
    if (!isFinite(lat) || !isFinite(lon)) return;

    const type = String(n.type || n.kind || '').toUpperCase();   // NDB/VOR/DME/TACAN/…
    const ident = n.ident || n.code || '';
    const name = n.name || '';

    // 1) icona (usa la tua funzione; fallback a un default se assente)
    let icon;
    try {
      icon = typeof getNavaidIcon === 'function' ? getNavaidIcon(type) : null;
    } catch { icon = null; }
    if (!icon) {
      icon = L.divIcon({
        className: 'navaid-marker route-clickable',
        html: `<svg viewBox="0 0 24 24" width="18" height="18"
                   xmlns="http://www.w3.org/2000/svg">
                 <g fill="none" stroke="currentColor" stroke-width="2"
                    stroke-linecap="round" stroke-linejoin="round">
                   <circle cx="12" cy="12" r="2"/>
                   <circle cx="12" cy="12" r="6"/>
                   <circle cx="12" cy="12" r="9"/>
                 </g>
               </svg>`,
        iconSize: [18, 18],
        iconAnchor: [9, 9]
      });
    }

    // 2) marker (dichiarato PRIMA di usarlo)
    const marker = L.marker([lat, lon], {
      icon,
      title: `${ident} ${name ? `- ${name}` : ''} (${type || 'NAVAID'})`
    });

    // 3) popup
    const freqMhz = n.frequency_mhz ?? (n.frequency_khz != null ? n.frequency_khz / 1000 : undefined);
    const dmeMhz = n.dme_frequency_mhz;
    const dmeChan = n.dme_channel;

    const popupHtml = `
      <b>${ident || '—'}${name ? ` - ${name}` : ''}</b><br>
      Tipo: ${type || 'N/D'}<br>
      Freq: ${freqMhz != null ? fmt.mhz(freqMhz) : (n.frequency_khz != null ? fmt.khzToMhz(n.frequency_khz) : 'N/D')}<br>
      DME: ${dmeChan ? `CH ${dmeChan}` : '—'} ${dmeMhz != null ? `(${fmt.mhz(dmeMhz)})` : ''}<br>
      Elev: ${n.elev_ft ?? 'N/D'} ft
    `;

    marker.bindPopup(popupHtml);

    // 4) click → aggiungi waypoint se Create Route è ON
    marker.on('click', () => {
      try {
        const on = (window.isManualRouteMode && window.isManualRouteMode()) || false;
        if (!on) return;
        if (typeof window.addWaypointManual !== 'function') return;

        const ident = n.ident || n.code || '';
        const nm = n.name || '';
        const kind = String(n.type || n.kind || '').toUpperCase();

        window.addWaypointManual({
          name: ident || nm || kind || 'NAVAID',
          lat: Number(n.lat),
          lon: Number(n.lon),
          type: kind || 'Navaid',
          source: 'navaid'
        });
      } catch (e) {
        console.warn('addWaypointManual (navaid) skipped:', e);
      }
    });

    // 4bis) doppio click → scrivi nel box ICAO e centra la mappa
    marker.on('dblclick', () => {
      try {
        const ident = n.ident || n.code || '';
        const latNum = Number(n.lat);
        const lonNum = Number(n.lon);
        if (window.focusOnSearchTarget) {
          window.focusOnSearchTarget({ icao: ident, lat: latNum, lon: lonNum });
        }
      } catch (e) {
        console.warn('navaid dblclick → focusOnSearchTarget failed:', e);
      }
    });

    // 5) aggiungi al layer
    navaidMarkers.addLayer(marker);
  });

  // Assicurati che il layer sia visibile
  if (!mapInstance.hasLayer(navaidMarkers)) {
    navaidMarkers.addTo(mapInstance);
  }
}


// Icona testuale per aeroporti "major" (ICAO-IATA)
function createAirportTextIcon(icao, iata) {
  const text = iata && iata !== 'N/A' ? `${icao}-${iata}` : icao;
  return L.divIcon({
    className: `${AIRPORT_MARKER_CLASS} route-clickable`,
    html: `<span>${text}</span>`,
    iconSize: [60, 20],
    iconAnchor: [30, 10]
  });
}

// Icona simbolica per aeroporti "major" (silhouette aereo, monocolore)
function createAirportSymbolIcon() {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="18" height="18"
         aria-label="Airport" role="img">
      <g fill="none" stroke="#007BFF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 2v8" />
        <path d="M4 10l8 3 8-3" />
        <path d="M9 22l3-6 3 6" />
        <path d="M3 13l6 1M21 13l-6 1" />
      </g>
    </svg>`;
  return L.divIcon({
    className: 'airport-symbol-marker ',   // ← aggiunta
    html: svg,
    iconSize: [24, 24],
    iconAnchor: [12, 12]
  });
}

const MINOR_AP_SVG = `
<svg viewBox="0 0 32 32" width="32" height="32"
     xmlns="http://www.w3.org/2000/svg"
     style="transform: rotate(180deg);">
  <path d="M10 10 L22 10 L18 22 L14 22 Z"
        fill="#007bff" stroke="white" stroke-width="1.8" stroke-linejoin="round"/>
  <path d="M16 12 L16 20"
        stroke="white" stroke-width="1.8" stroke-dasharray="2 2" stroke-linecap="round"/>
</svg>`;

function createMinorAirportIcon() {
  return L.divIcon({
    className: 'minor-airport-marker route-clickable',    // ← aggiunta
    html: MINOR_AP_SVG,
    iconSize: [32, 32],
    iconAnchor: [16, 16]
  });
}

const HELIPORT_SVG = `
<svg viewBox="0 0 32 32" width="24" height="24" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="5" width="22" height="22" rx="5" ry="5"
        fill="#6a1b9a" stroke="white" stroke-width="2"/>
  <text x="16" y="22" text-anchor="middle"
        fill="white" font-size="14" font-weight="bold"
        font-family="Arial, sans-serif">H</text>
</svg>`;

function createHeliportIcon() {
  return L.divIcon({
    className: 'heliport-marker route-clickable',         // ← aggiunta
    html: HELIPORT_SVG,
    iconSize: [24, 24],
    iconAnchor: [12, 12]
  });
}



/**
 * Disegna gli aeroporti sulla mappa, filtrando in base ai tre toggle.
 * @param {Array<Object>} airports - Oggetti aeroporto dal backend.
 * @param {L.Map} mapInstance      - Istanza Leaflet.
 * @param {boolean} showMinor      - Mostra aviosuperfici/minor.
 * @param {boolean} showMajor      - Mostra aeroporti maggiori.
 * @param {boolean} showHeliports  - Mostra eliporti.
 * @param {boolean} [allowMajorLabels=true] - Se true usa etichetta ICAO/IATA per i major, altrimenti il simbolo.
 */
function drawAirports(airports, mapInstance, showMinor, showMajor, showHeliports, allowMajorLabels = true) {
  // Pulisci sempre il layer prima di ridisegnare
  airportMarkers.clearLayers();

  if (!Array.isArray(airports) || airports.length === 0) {
    if (mapInstance.hasLayer(airportMarkers)) mapInstance.removeLayer(airportMarkers);
    return;
  }

  airports.forEach(a => {
    const lat = Number(a.lat), lon = Number(a.lon);
    if (!isFinite(lat) || !isFinite(lon)) return;

    const tRaw = (a.type ?? a.kind ?? '').toString();
    const t = tRaw.toLowerCase();
    const icao = (a.icao ?? '').toString();
    const iata = (a.iata ?? a.iata_code ?? '').toString();

    const isHeli = t === 'heliport' || /heli/.test(t);
    const isClosed = t === 'closed';
    const isMinor = !isHeli && (
      /small_airport|seaplane/.test(t) ||
      icao.includes('-')                      // tua euristica “codice con trattino”
    );
    const isMajor = !isHeli && !isMinor;     // tutto il resto

    // Esclusioni e visibilità in base ai toggle
    if (isClosed) return;
    if (isHeli && !showHeliports) return;
    if (isMinor && !showMinor) return;
    if (isMajor && !showMajor) return;

    // Scegli l’icona
    let icon;
    if (isHeli) {
      icon = createHeliportIcon();
    } else if (isMinor) {
      icon = createMinorAirportIcon();
    } else {
      icon = allowMajorLabels
        ? createAirportTextIcon(icao, iata || '')
        : (typeof createAirportSymbolIcon === 'function'
          ? createAirportSymbolIcon()
          : createAirportTextIcon(icao, iata || ''));
    }

    // Crea il marker PRIMA di usarlo
    const marker = L.marker([lat, lon], {
      icon,
      title: `${icao}${iata ? `/${iata}` : ''}${a.name ? ` - ${a.name}` : ''}`
    });

    // Popup informativo
    const popupHtml = `
      <b>${icao}${iata ? `/${iata}` : ''}${a.name ? ` - ${a.name}` : ''}</b><br>
      City: ${a.municipality || 'N/D'}<br>
      Type: ${tRaw || 'N/D'}<br>
      Elev: ${a.elev_ft ?? 'N/D'} ft
    `;
    marker.bindPopup(popupHtml);

    // Click: se modalità “Create Route” è ON, aggiungi waypoint
    marker.on('click', () => {
      const isOn =
        (window.isManualRouteMode && window.isManualRouteMode()) ||
        (window.route && window.route.isManualRouteMode && window.route.isManualRouteMode()) ||
        false;

      const add =
        window.addWaypointManual ||
        (window.route && window.route.addWaypointManual);

      if (!isOn || typeof add !== 'function') return;

      const typeLabel = isHeli ? 'Heliport' : 'Airport';
      const name = icao || iata || a.name || 'APT';
      add({ name, lat, lon, type: typeLabel, source: 'airport' });
    });

    // Doppio click: copia nel box ICAO e centra la mappa
    marker.on('dblclick', () => {
      try {
        const code = icao || iata || a.name || '';
        const latNum = lat;
        const lonNum = lon;
        if (window.focusOnSearchTarget) {
          window.focusOnSearchTarget({ icao: code, lat: latNum, lon: lonNum });
        }
      } catch (e) {
        console.warn('airport dblclick → focusOnSearchTarget failed:', e);
      }
    });

    // Aggiungi al layer
    airportMarkers.addLayer(marker);
  });

  // Assicurati che il layer sia visibile
  if (!mapInstance.hasLayer(airportMarkers)) {
    airportMarkers.addTo(mapInstance);
  }
}



/***
 * Export function
 * ES6 syntax short form*
 */
export {
  elements,
  initializeMap,
  updateMapCoverage,
  updateAircraftPosition,
  renderFlightPath,
  populateSdwnDropdown,
  getJobParameters,
  renderSvgButtons,
  toggleMapSelectionMode,
  showIcaoMode,
  showTileInPanel,
  previewArea,
  clearPreview,
  setupInteractiveSelection,
  updateHandleStyles,
  linkRadiusHandleToInput,
  updateFgfsIndicator,
  populateMapServerSelector,
  drawCircle,
  showIcaoSuggestions,
  hideIcaoSuggestions,
  drawNavaids,
  drawAirports,
  airportMarkers,
  ICAO_SUGGESTION_ID,
  renderVisibilityFilters
};


