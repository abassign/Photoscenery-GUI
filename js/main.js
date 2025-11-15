// Save as: js/main.js (final version)

import * as route from './route.js';
import { saveActivatedRouteAsGpx } from './route.js';
import { openSaveRouteModal } from './route.js';
import {
    setManualRouteMode,
    isManualRouteMode,
    addWaypointManual,
    clearManualRoute,
    removeWaypointAt,
    highlightWaypoint,
    computeLegDistancesNM,
    getManualRouteWaypoints
} from './route.js';

import * as api from './api.js';

import { startPollers, fetchCoverageOnce } from './api.js';
import { resolveIcao, airportsSearch } from './api.js';

import { showSearchMarker, removeSearchMarker } from './ui.js';

import {
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
} from './ui.js';

window.setManualRouteMode = setManualRouteMode;
window.isManualRouteMode  = isManualRouteMode;
window.addWaypointManual  = addWaypointManual;
window.clearManualRoute   = clearManualRoute;
window.removeWaypointAt   = removeWaypointAt;
window.highlightWaypoint  = highlightWaypoint;
window.computeLegDistancesNM = computeLegDistancesNM;
window.focusOnSearchTarget = focusOnSearchTarget;

// ---------- DEBUG SWITCH ----------
window.DEBUG_FGFS = true;        // flip to false to silence
const log = (...a) => window.DEBUG_FGFS && console.log('[DEBUG-JS]', ...a);

// --- Aircraft-auto-queue settings ---
const RADIUS_AROUND_AC = 20;   // NM of each circle
const OVERLAP_FACTOR   = 0.33;  // ⅔ diameter offset
const MIN_JOB_INTERVAL_MS = 3000; // anti-flood throttle

const DATE_FILTER_LABELS = ["This Session", "Today", "Yesterday", "Last Week", "Last Month", "Last Year", "All Time"];

// --- Global State ---
const state = {
    isConnected: false,             // FlightGear connection status
    isMapSelectionMode: false,      // Whether map coordinate selection is active
    currentOpacity: 0.4,            // Current opacity level for map coverage
    resState: Array(7).fill(true),  // Active/inactive state for each resolution filter
    hasPreview: false,
    previewAreas: [],
    isDragging: false,
    followAircraftActive: false,    // Lo stato della modalità: ON/OFF
    followAircraftAllowed: false,   // Se la modalità PUÒ essere attivata (FGFS connesso, etc.)
    isAutoJobPending: false,        // Flag per prevenire il re-trigger rapido dei job DAA
    lastDaaCircleId: null,          // ID dell'ultimo cerchio DAA creato
    lastDaaOriginPoint: null,       // Posizione dell'aereo all'ultimo trigger DAA
    sessionStartTime: null,         // Aggiungi: Ora di avvio della sessione
    dateFilterIndex: 6,             // Aggiungi: Indice del filtro (default: 6 = All Time)
    lastDaaCenterPoint: null,       // centro dell’ultimo cerchio verde
    lastAutoLaunchTs: 0,            // timestamp ultimo invio autoù
    lastDaaCircleLayer: null,       // riferimento diretto all’ultimo cerchio verde
    daaArmed: false,                // isteresi: diventa true solo dopo essere entrati sotto ARM_TH
    defaultServerId: 1,
    flightPath: [],
    isFlightPathVisible: true,
    lowDetailThreshold: 1.0,
    isAirportsVisible: true,
    visibilityFilters: {
        tiles: true,                // Visibilità copertura Tiles (DDS)
        airports: true,             // Visibilità Marker Aeroporti (non implementato, ma preparato)
        navaids: true,              // Visibilità Marker Navaids
        route: true,                // Visibilità Polilinea Rotta
        minorAirports: false,       // Visibilità aeroporti
        heliports: false            // Visibilità eliporti
    }
};

const activeCircles = {};           // Stores active job circles on the map
const jobCompletionCallbacks = window.jobCompletionCallbacks || (window.jobCompletionCallbacks = new Map());

let pendingCircle = null;           // Temporary Leaflet circle object

let navaidsLoadTimer = null;


// ---------- Utils centro->esterno ----------
function haversineKm(lat1, lon1, lat2, lon2) {
  const toRad = d => d * Math.PI / 180;
  const R = 6371.0088;
  const dLat = toRad(lat2 - lat1);
  let dLon = lon2 - lon1;
  // gestisci antimeridiano
  if (dLon > 180) dLon -= 360;
  if (dLon < -180) dLon += 360;
  dLon = toRad(dLon);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLon/2)**2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}


/**
 * Carica e disegna solo i layer realmente visualizzabili, in base allo span corrente:
 * - > 60°: niente (protezione)
 * - 30°..60°: solo airports_major + navaids (se togglati)
 * - ≤ 30°: airports_major (+etichette), airports_minor, heliports, navaids (se togglati)
 */
async function loadAndDrawNavaids(mapInstance) {
  const MAX_SPAN_MAJOR_AP_NAVAID = 60.0;
  const MAX_SPAN_MINOR_AP        = 10.0;
  const MAX_RESULTS_TOTAL        = 1500;   // cap totale (server gestirà per-tipo)

  const b = mapInstance.getBounds();
  const nwLat = b.getNorth(), nwLon = b.getWest();
  const seLat = b.getSouth(), seLon = b.getEast();

  const latSpan = nwLat - seLat;
  const lonSpan = (nwLon <= seLon) ? (seLon - nwLon) : (seLon + 360 - nwLon);

  const isMajorAreaTooBig = latSpan > MAX_SPAN_MAJOR_AP_NAVAID || lonSpan > MAX_SPAN_MAJOR_AP_NAVAID;
  const isMinorAreaTooBig = latSpan > MAX_SPAN_MINOR_AP || lonSpan > MAX_SPAN_MINOR_AP;

  // protezione
  if (isMajorAreaTooBig) {
    console.warn(`GeoData: area > ${MAX_SPAN_MAJOR_AP_NAVAID}° — niente fetch.`);
    drawNavaids([], mapInstance);
    drawAirports([], mapInstance, false, false, false);
    return;
  }

  // Costruisci l’elenco dei tipi realmente visualizzabili
  const wantNavaids   = state.visibilityFilters.navaids && true; // consentiti fino a 60°
  const wantMajor     = state.visibilityFilters.airports && true; // consentiti fino a 60°
  const wantMinor     = state.visibilityFilters.minorAirports && !isMinorAreaTooBig;
  const wantHeliports = state.visibilityFilters.heliports && !isMinorAreaTooBig;

  const types = [];
  if (wantNavaids)   types.push('navaids');
  if (wantMajor)     types.push('airports_major'); // <=60°
  if (wantMinor)     types.push('airports_minor'); // solo ≤30°
  if (wantHeliports) types.push('heliports');      // solo ≤30°

  // Se non c'è nulla da mostrare, pulisci e basta
  if (types.length === 0) {
    drawNavaids([], mapInstance);
    drawAirports([], mapInstance, false, false, false);
    return;
  }

  // Unica chiamata (server esteso con sottotipi) + fallback “vecchio server”
  const base = `/api/geo/box?nw_lat=${nwLat}&nw_lon=${nwLon}&se_lat=${seLat}&se_lon=${seLon}`;
  const url  = `${base}&types=${encodeURIComponent(types.join(','))}&max_total=${MAX_RESULTS_TOTAL}`;

  try {
    const r = await fetch(url);
    if (!r.ok) throw new Error('non-200');
    const data = await r.json();

    // Etichette major solo se ≤30°
    const allowMajorLabels = !isMinorAreaTooBig;

    // Combina i sottotipi richiesti (INCLUSI gli HELIPORTS)
    const airportsCombined = []
      .concat(wantMajor     ? (data.airports_major  || []) : [])
      .concat(wantMinor     ? (data.airports_minor  || []) : [])
      .concat(wantHeliports ? (data.heliports       || []) : []);

    // Disegna
    drawNavaids(data.navaids || [], mapInstance);
    drawAirports(
      airportsCombined,
      mapInstance,
      !!wantMinor,     // showMinor
      !!wantMajor,     // showMajor
      !!wantHeliports, // showHeliports
      allowMajorLabels
    );

  } catch (e) {
    // Fallback: server non supporta sottotipi → due fetch come prima (airports + navaids), ma con filtri lato client
    console.warn('Server senza sottotipi types=…, uso fallback:', e);

    // 1) Navaids (se richiesti)
    if (wantNavaids) {
      try {
        const rn = await fetch(`${base}&types=navaids&max_navaids=${MAX_RESULTS_TOTAL}`);
        const dn = rn.ok ? await rn.json() : { navaids: [] };
        drawNavaids(dn.navaids || [], mapInstance);
      } catch { drawNavaids([], mapInstance); }
    } else {
      drawNavaids([], mapInstance);
    }

    // 2) Airports (filtro client per major/minor/heli)
    try {
      const ra = await fetch(`${base}&types=airports&max_airports=${MAX_RESULTS_TOTAL}`);
      const da = ra.ok ? await ra.json() : { airports: [] };
      const all = da.airports || [];

      // separa i sottotipi in fallback: usa 'type' (OurAirports) o 'kind' come alternativa
      const getType = a => String(a.type ?? a.kind ?? "").toLowerCase();
      const helis  = all.filter(a => /heliport/.test(getType(a)));
      const majors = all.filter(a => /large_airport|medium_airport/.test(getType(a)) || (a.iata && String(a.iata).length > 0));
      const minors = all.filter(a => !helis.includes(a) && !majors.includes(a));

      const allowMajorLabels = !isMinorAreaTooBig;

      drawAirports(
        (wantMinor ? minors : []).concat(wantHeliports ? helis : []).concat(wantMajor ? majors : []),
        mapInstance,
        !!wantMinor,
        !!wantMajor,
        !!wantHeliports,
        allowMajorLabels
      );
    } catch {
      drawAirports([], mapInstance, false, false, false);
    }
  }
}

/**
 * Main update loop that runs periodically
 * - Updates aircraft position if connected
 * - Updates map coverage with current filters and opacity
 */
function mainUpdateLoop() {
    if (state.isConnected) {
        api.getFgfsStatus().then(data => {
            // Prima aggiorna la posizione sulla mappa
            updateAircraftPosition(data);
            if (data.active) {
                const lastPoint = state.flightPath.length > 0 ? state.flightPath[state.flightPath.length - 1] : null;
                // Aggiungi un punto solo se la posizione è cambiata
                if (!lastPoint || lastPoint.lat !== data.lat || lastPoint.lon !== data.lon) {
                    state.flightPath.push({
                        lat: data.lat,
                        lon: data.lon,
                        heading: data.heading,
                        altitude_ft: data.altitude, // Quota MSL
                        // NOTA: Il backend attualmente non fornisce la quota AGL.
                        // Se la aggiungerai in futuro, andrà inserita qui.
                        speed_kts: data.speed,
                        isActivated: false
                    });
                    // Aggiorna la linea sulla mappa
                    renderFlightPath(state.flightPath, state.isFlightPathVisible && state.visibilityFilters.route);
                }
            }
            // POI salva la rotta nello stato globale
            state.currentHeading = data.heading;
        });
        updateFollowAircraftAvailability();
    }

    api.fetchCoverageOnce((coverageData) => {
        // -------------------------------------------------------------
        // NUOVO CONTROLLO: Se il filtro Tiles è disattivato, pulisci e termina.
        if (!state.visibilityFilters.tiles) {
            // La variabile 'coverageLayer' è definita in ui.js e usata in updateMapCoverage.
            // Poiché non puoi accedere a 'coverageLayer' direttamente in main.js,
            // devi pulire il layer all'interno di updateMapCoverage se il filtro è false,
            // oppure aggiungere una funzione 'clearCoverage' in ui.js.

            // OPZIONE A (PIÙ PULITA, richiede una funzione in ui.js):
            // clearCoverageLayer();

            // OPZIONE B (PIÙ SEMPLICE, basata sull'ultima modifica del piano):
            // Se non chiami updateMapCoverage, le tiles rimangono visibili.
            // Devi forzare la pulizia se il filtro è disattivo.

            // PER ORA: Ci affidiamo alla logica che DOPO aver aggiornato lo stato
            // e chiamato mainUpdateLoop, il filtro verrà applicato.

            // ******************************************************************
            // Modifica la funzione 'updateMapCoverage' in ui.js per gestire la pulizia
            // e qui aggiungiamo il controllo:
            // ******************************************************************

            // Chiamiamo la funzione di aggiornamento con dati vuoti per forzare la pulizia
            updateMapCoverage(
                [], // Passa un array vuoto
                new Set(),
                state.currentOpacity,
                state.dateFilterIndex,
                state.sessionStartTime,
                state.lowDetailThreshold
            );
            return; // Termina la callback
        }
        // -------------------------------------------------------------

        const allowedResolutions = new Set(
            state.resState.map((active, i) => active ? i : -1).filter(i => i !== -1)
        );

        updateMapCoverage(
            coverageData,
            allowedResolutions,
            state.currentOpacity,
            state.dateFilterIndex,
            state.sessionStartTime,
            state.lowDetailThreshold
        );
    });
}

/**
 * Handles resolution filter button clicks
 * @param {number} index - Index of the clicked resolution filter
 */
function handleResFilterClick(index) {
    state.resState[index] = !state.resState[index];
    renderSvgButtons(state.resState, handleResFilterClick);
    mainUpdateLoop();
}

// ------------------------------------------------------------------
// 2. Draw/Clear transparent green circles for jobs
// ------------------------------------------------------------------

function updateCoordinates(lat, lon) {
    elements.latInput.value = lat.toFixed(6);
    elements.lonInput.value = lon.toFixed(6);
    elements.icaoInput.value = `Coords: ${lat.toFixed(4)}, ${lon.toFixed(4)}`;
}

function updatePreview() {
    if (elements.latInput.value && elements.lonInput.value && elements.radiusInput.value) {
        previewArea(
            parseFloat(elements.latInput.value),
                    parseFloat(elements.lonInput.value),
                    parseFloat(elements.radiusInput.value)
        );
        state.hasPreview = true;

        // Centra la mappa sull'area selezionata
        elements.map.setView(
            [parseFloat(elements.latInput.value), parseFloat(elements.lonInput.value)],
                             elements.map.getZoom()
        );
    }
}

/**
 * Removes a job circle from the map
 * @param {string} jobId - Unique job identifier
 */
function clearCircle(jobId) {
    const layer = activeCircles[jobId];
    if (layer) {
        elements.map.removeLayer(layer);      // remove from map
        delete activeCircles[jobId];          // remove from registry
    }
}

/**
 * Checks for and clears circles of completed jobs
 */
function checkCompletedJobs() {
    api.getCompletedJobs().then(ids => {
        if (ids.length > 0) {
            ids.forEach(id => {
                // 1. Rimuovi il cerchio dalla mappa (come prima)
                clearCircle(id);
                // 2. Controlla se c'è una callback registrata per questo job e eseguila
                if (jobCompletionCallbacks.has(id)) {
                    const callback = jobCompletionCallbacks.get(id);
                    callback(id); // Esegui la callback
                    jobCompletionCallbacks.delete(id); // Rimuovila dopo l'uso
                }
            });
        }
    });
}

// ------------------------------------------------------------------
// DDA Download Around Aircraft (DAA)
// ------------------------------------------------------------------

/**
 * Updates the availability and appearance of the "Download around aircraft" feature.
 * This function enables/disables the button and manages the mutual exclusivity
 * with the "Execute Job" button. It's now the single source of truth for the UI state.
 */
function updateFollowAircraftAvailability() {
    const btnFollow = elements.btnDownloadAroundAircraft;
    const sdwnSelect = elements.sdwnSelect;

    if (!btnFollow || !sdwnSelect) return;

    state.followAircraftAllowed = state.isConnected && Number.isFinite(state.currentHeading);
    btnFollow.disabled = !state.followAircraftAllowed;

    if (state.followAircraftActive && state.followAircraftAllowed) {
        btnFollow.style.backgroundColor = "#28a745";
        btnFollow.style.color = "white";
        sdwnSelect.disabled = true;
    } else {
        btnFollow.style.backgroundColor = "";
        btnFollow.style.color = "";
        sdwnSelect.disabled = false;
    }
}


// ------------------------------------------------------------------
// 3. Event Handling
// ------------------------------------------------------------------
elements.controlsPanel.addEventListener('click', (e) => {
    const t = e.target.closest('button');
    if (!t) return;

    switch (t.id) {

        case 'btn-download-around-aircraft':
            // This button now acts as a toggle switch for the "Follow Aircraft" mode.

            if (!state.followAircraftAllowed) {
                alert('Connect to FlightGear first and ensure the aircraft has a heading.');
                break;
            }

            // Toggle the state
            state.followAircraftActive = !state.followAircraftActive;

            if (state.followAircraftActive) {
                // --- ACTIVATING the mode ---
                // CORREZIONE: Chiama la nuova e corretta funzione
                startAutomaticFollowJob();
            } else {
                // Chiama la nuova funzione per pulire i cerchi dalla mappa.
                clearAllDaaCircles();
            }
            // Aggiorna sempre la UI dopo aver cambiato stato
            updateFollowAircraftAvailability();
            break;

        case 'btn-stop':
            if (confirm("Stop the server?")) api.shutdownServer();
            break;

        case 'btn-get-coords':
            if (state.isConnected) {
                api.getFgfsStatus().then(data => {
                    if (data.active) {
                        elements.latInput.value = data.lat.toFixed(6);
                        elements.lonInput.value = data.lon.toFixed(6);
                        elements.icaoInput.value = `Coords: ${data.lat.toFixed(4)}, ${data.lon.toFixed(4)}`;
                    }
                });
            }
            break;
        case 'btn-select-from-map':
            state.isMapSelectionMode = !state.isMapSelectionMode;
            toggleMapSelectionMode(state.isMapSelectionMode);
            break;
    }
});


// Event listeners
elements.sizeInput.addEventListener('input', populateSdwnDropdown);
elements.opacitySlider.addEventListener('input', (e) => {
    state.currentOpacity = parseFloat(e.target.value);
    mainUpdateLoop();
});


// Tile preview popup handler
elements.map.on('popupopen', (e) => {
    const previewBtn = e.popup._container.querySelector('.preview-button');
    if (previewBtn) {
        previewBtn.onclick = () => {
            const tileId = previewBtn.dataset.tileId;
            const sizeId = parseInt(previewBtn.dataset.sizeId, 10);
            const previewUrl = api.getTilePreview(tileId, 512); // anteprima veloce
            const nativeUrl  = api.getTilePreview(tileId, 512 << sizeId); // full-res download
            showTileInPanel(tileId, sizeId, previewUrl, nativeUrl);
        };
    }
});

elements.radiusInput.addEventListener('input', () => {
    // Find the currently active (un-fixed) preview circle
    const preview = state.previewAreas.find(a => !a.isFixed);
    if (preview && preview.circle) {
        // Update its radius from the input value
        const newRadiusMeters = (parseFloat(elements.radiusInput.value) || 0) * 1852;
        if (newRadiusMeters > 0) {
            preview.circle.setRadius(newRadiusMeters);
        }
        // Update handle styles to reflect the new size
        updateHandleStyles(preview.circle);
    }
});

elements.dateFilterSlider.addEventListener('input', (e) => {
    const value = parseInt(e.target.value, 10);
    state.dateFilterIndex = value; // Aggiorna lo stato
    elements.dateFilterLabel.textContent = DATE_FILTER_LABELS[value]; // Aggiorna l'etichetta
    mainUpdateLoop(); // Forza l'aggiornamento della mappa
});

// ------------------------------------------------------------------
// --- Aircraft-auto-queue settings ---
// ------------------------------------------------------------------
function destinationPoint(lat, lon, dNm, bearingDeg) {
    const R = 6371;
    const δ = (dNm * 1.852) / R;
    const θ = bearingDeg * Math.PI / 180;
    const φ1 = lat * Math.PI / 180;
    const λ1 = lon * Math.PI / 180;

    const φ2 = Math.asin(Math.sin(φ1) * Math.cos(δ) +
    Math.cos(φ1) * Math.sin(δ) * Math.cos(θ));
    const λ2 = λ1 + Math.atan2(Math.sin(θ) * Math.sin(δ) * Math.cos(φ1),
                               Math.cos(δ) - Math.sin(φ1) * Math.sin(φ2));
    return { lat: φ2 * 180 / Math.PI, lon: λ2 * 180 / Math.PI };
}


/**
 * Handles the "Download Around Aircraft" automatic job submission.
 * This process is fully automated:
 * 1. It forces overwrite mode to 2 for tile replacement.
 * 2. It reads the radius and the desired minimum resolution (--sdwn) from the GUI.
 * 3. It sends these parameters to the Julia backend.
 * 4. The backend handles the adaptive resolution logic based on altitude and distance.
 * 5. It draws a green, confirmed circle and immediately starts the download.
 */
function startAutomaticFollowJob() {
    state.isAutoJobPending = true;

    // 1. Get real-time aircraft data
    api.getFgfsStatus().then(data => {
        if (!data.active) {
            alert('Cannot start job: aircraft data not available.');
            state.followAircraftActive = false;
            updateFollowAircraftAvailability();
            return;
        }

        state.lastDaaOriginPoint = L.latLng(data.lat, data.lon);

        const radiusNm  = parseFloat(elements.radiusInput.value) || 20;
        const ahead = destinationPoint(data.lat, data.lon, radiusNm * OVERLAP_FACTOR, data.heading);

        const jobParams = {
            lat: ahead.lat,
            lon: ahead.lon,
            radius: radiusNm,
            over: parseInt(elements.overSelect.value, 10) || 1,
            size: parseInt(elements.sizeInput.value, 10) || 4,
            sdwn: parseInt(elements.sdwnSelect.value, 10) || 0,
            mode: 'daa',
            server: parseInt(elements.mapServerSelect.value, 10) || state.defaultServerId
        };

        const circle = L.circle([ahead.lat, ahead.lon], {
            radius: radiusNm * 1852,
            color: '#00cc00',
            fillColor: '#00cc00',
            fillOpacity: 0.15,
            weight: 1.5
        }).addTo(elements.map);

        state.lastDaaCircleLayer = circle;

        // SALVA il centro del cerchio corrente per il prossimo trigger
        state.lastDaaCenterPoint = circle.getLatLng();
        state.daaArmed = false;  // all’inizio NON siamo armati: prima bisogna avvicinarsi

        return api.startJob(jobParams).then(jobData => {
            activeCircles[jobData.jobId] = circle;
            state.lastDaaCircleId = jobData.jobId;
            console.log(`Automatic job #${jobData.jobId} started (k_max=${jobParams.size}).`);
            state.lastAutoLaunchTs = 0; // reset throttle per il prossimo tick
        }).catch(err => {
            elements.map.removeLayer(circle);
            alert(`Error starting automatic job: ${err.message}`);
            state.followAircraftActive = false;
            updateFollowAircraftAvailability();
        });
    }).finally(() => {
        // libera SEMPRE il trigger (anche in caso di errore)
        state.isAutoJobPending = false;
        state.lastAutoLaunchTs = Date.now();
    }).catch(() => {
        // (il catch dopo finally serve solo se la Promise outer lancia prima)
    });
}


function processQueueSequentially() {
    const next = state.previewAreas.find(a => !a.isFixed);
    if (!next) return;

    const params = {
        lat   : next.lat,
        lon   : next.lon,
        radius: next.radius,
        size  : parseInt(elements.sizeInput.value) || 4,
        over  : parseInt(elements.overSelect.value)  || 1,
        sdwn  : parseInt(elements.sdwnSelect.value)  || -1
    };

    api.startJob(params)
    .then(data => {
        // Promote orange → green
        const c = next.circle;
        c.pm.disable();
        c.setStyle({ color: '#00cc00', fillColor: '#00cc00', fillOpacity: 0.15, dashArray: null });
        activeCircles[data.jobId] = c;

        const idx = state.previewAreas.indexOf(next);
        if (idx > -1) state.previewAreas.splice(idx, 1);

        // Wait for Julia “completed” then start next
        const checkNext = () => {
            api.getCompletedJobs().then(ids => {
                if (ids.includes(data.jobId)) {
                    processQueueSequentially();
                } else {
                    setTimeout(checkNext, 1000);
                }
            });
        };
        checkNext();
    })
    .catch(err => alert(`Error: ${err.message}`));
}


/**
 * Auto-follow logic for "Download around aircraft".
 * Generates new ahead-positioned circles when the aircraft moves
 * close to the center of the current job circle.
 */
function checkAutoFollow() {
    const now = Date.now();
    const throttleOk = (now - state.lastAutoLaunchTs) >= MIN_JOB_INTERVAL_MS;
    if (!state.followAircraftActive || state.isAutoJobPending || !throttleOk) {
        return;
    }

    api.getFgfsStatus().then(data => {
        if (!data.active) return;

        // --- NUOVO CONTROLLO DI SICUREZZA ---
        // Se l'aereo è troppo lento (es. meno di 10 kts), non fare nulla.
        // Questo previene errori con dati di heading instabili da fermo.
        if (data.speed < 10) {
            // Resettiamo lo stato di "armo" per essere pronti quando la velocità aumenta
            state.daaArmed = false;
            return;
        }
        // --- FINE CONTROLLO ---

        const lastCircle = state.lastDaaCircleLayer;

        if (!lastCircle) {
            // If there is no active DAA circle, and we are in DAA mode, we create one
            startAutomaticFollowJob();
            return;
        }

        const acPos   = L.latLng(data.lat, data.lon);
        const radius  = lastCircle.getRadius();
        const centre  = state.lastDaaCenterPoint || lastCircle.getLatLng();

        const distToCtr = acPos.distanceTo(centre);
        const FIRE_TH   = radius * OVERLAP_FACTOR;
        const ARM_TH    = radius * (OVERLAP_FACTOR * 0.7);

        if (!state.daaArmed) {
            if (distToCtr <= ARM_TH) {
                state.daaArmed = true;
            }
            return;
        }

        if (distToCtr >= FIRE_TH) {
            startAutomaticFollowJob();
            state.daaArmed = false;
        }
    });
}


/**
 * Removes all green job circles created by the DAA mode from the map.
 */
function clearAllDaaCircles() {
    // Itera su tutti i cerchi attivi registrati
    for (const jobId in activeCircles) {
        const layer = activeCircles[jobId];
        if (layer) {
            elements.map.removeLayer(layer); // Rimuove dalla mappa
            delete activeCircles[jobId];     // Rimuove dalla registro
        }
    }
    state.lastDaaCircleId = null;
    state.lastDaaOriginPoint = null;
    state.lastDaaCenterPoint = null;
    state.lastDaaCircleLayer = null;
    state.daaArmed = false;
    console.log("DAA: Cleared all active job circles.");
}


/**
 * Filtra i punti attivati dal percorso di volo e li salva in un file XML
 * formattato per FlightGear.
 */
// RINOMINATA LA FUNZIONE
function saveRouteToXml(flightPath) {
    // 1. Filtra solo i punti che l'utente ha attivato cliccandoci sopra.
    const activatedPoints = flightPath.filter(p => p.isActivated);

    if (activatedPoints.length === 0) {
        alert("Nessun waypoint è stato attivato. Clicca sui punti arancioni del percorso per selezionarli prima di salvare.");
        return;
    }

    // 2. Costruisce la stringa XML (invariato).
    let xmlString = '<?xml version="1.0"?>\n<FlightPlan>\n';
    activatedPoints.forEach((point, index) => {
        const ident = `WP${index + 1}`;
        const lat = point.lat.toFixed(6);
        const lon = point.lon.toFixed(6);
        const alt = Math.round(point.altitude_ft);

        xmlString += '    <waypoint>\n';
        xmlString += `        <ident>${ident}</ident>\n`;
        xmlString += `        <lat>${lat}</lat>\n`;
        xmlString += `        <lon>${lon}</lon>\n`;
        xmlString += `        <alt>${alt}</alt>\n`;
        xmlString += '    </waypoint>\n';
    });
    xmlString += '</FlightPlan>';

    // 3. --- BLOCCO DI SALVATAGGIO MODIFICATO ---
    const blob = new Blob([xmlString], { type: 'application/xml' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;

    // Crea il nome del file con il timestamp, come per "Save Path"
    const timestamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
    a.download = `flight-route-${timestamp}.xml`; // Nuovo nome file

    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
}

// Funzione per mostrare/nascondere il layer degli aeroporti
function toggleAirportsVisibility(isVisible) {
    state.isAirportsVisible = isVisible;
    if (isVisible) {
        elements.map.addLayer(airportMarkers);
        // Forza un aggiornamento per caricare i dati (se il layer era spento)
        // updateMapDataAndOverlays(); // La funzione che effettua il fetch dei dati
    } else {
        elements.map.removeLayer(airportMarkers);
    }
}


// ------------------------------------------------------------------
// Map click handler for coordinate selection
// ------------------------------------------------------------------
elements.map.on('click', (e) => {
    if (state.isDragging || !state.isMapSelectionMode) {
        return;
    }
    // Chiama la nuova funzione riutilizzabile passando le coordinate del click
    createPreviewCircleAt(e.latlng.lat, e.latlng.lng);
});

// ---------- Auto-connect on start-up ----------
window.addEventListener('DOMContentLoaded', () => {
    const port = parseInt(elements.fgfsPortInput.value, 10) || 5000;
    api.connectToFgfs(port);
});


/**
 * Creates a complete, interactive preview circle at a specific location.
 * @param {number} lat - Latitude for the circle's center.
 * @param {number} lon - Longitude for the circle's center.
 */
function createPreviewCircleAt(lat, lon) {
    let radiusNm = parseFloat(elements.radiusInput.value) || 3;
    if (radiusNm < 3) radiusNm = 3;
    elements.radiusInput.value = radiusNm;

    updateCoordinates(lat, lon); // CORRETTO: usa 'lon'

    const circle = previewArea(lat, lon, radiusNm); // CORRETTO: usa 'lon'
    linkRadiusHandleToInput(circle);

    const areaState = { lat, lon, radius: radiusNm, circle, isFixed: false }; // CORRETTO: usa 'lon'
    state.previewAreas.push(areaState);

    // Bottoni di conferma e cancellazione
    const btnGroup = L.layerGroup().addTo(elements.map);
    const rLatDeg = circle.getRadius() / 111320;

    const okBtn = L.marker([lat + rLatDeg, lon], { // CORRETTO: usa 'lon'
        icon: L.divIcon({
            html: '<button class="mini-btn ok">✓</button>',
            className: 'mini-btn-container', iconSize: [22, 22], iconAnchor: [11, 11]
        })
    }).addTo(btnGroup);

    const delBtn = L.marker([lat - rLatDeg, lon], { // CORRETTO: usa 'lon'
        icon: L.divIcon({
            html: '<button class="mini-btn del">🗑</button>',
            className: 'mini-btn-container', iconSize: [22, 22], iconAnchor: [11, 11]
        })
    }).addTo(btnGroup);

    // Set a flag when a drag operation starts (on the circle body OR its handles)
    circle.on('pm:dragstart pm:markerdragstart', () => {
        state.isDragging = true;
    });

    // Reset the flag when the drag ends.
    // The timeout ensures this runs *after* the map's click event has been
    // processed, effectively ignoring the click that concludes the drag.
    circle.on('pm:dragend pm:markerdragend', () => {
        setTimeout(() => {
            state.isDragging = false;
        }, 0);
    });

    // --- Eventi sui bottoni ---
    okBtn.on('click', (event) => {
        L.DomEvent.stop(event);

        // Congela il cerchio (niente più editing) e rimuove i bottoni
        circle.pm.disable();
        elements.map.removeLayer(btnGroup);

        // Parametri job → direttamente dal cerchio e dai controlli
        const centre = circle.getLatLng();
        const params = {
            lat: centre.lat,
            lon: centre.lng,
            radius: circle.getRadius() / 1852, // m → NM
            size: parseInt(elements.sizeInput.value, 10) || 4,
            over: parseInt(elements.overSelect.value, 10) || 1,
            sdwn: parseInt(elements.sdwnSelect.value, 10) || 0, // default 0 ⇒ precoverage ON
            mode: 'manual',
            server: parseInt(elements.mapServerSelect.value, 10) || state.defaultServerId
        };

        // Avvia subito il job e trasforma il cerchio in "verde"
        api.startJob(params)
        .then(data => {
            circle.setStyle({
                color: '#00cc00',
                fillColor: '#00cc00',
                fillOpacity: 0.15,
                dashArray: null
            });
            activeCircles[data.jobId] = circle;
            areaState.isFixed = true; // ormai è “confermato”
            // Call the imported drawCircle function, passing activeCircles
            drawCircle(data.jobId, data.lat, data.lon, data.radius, activeCircles);
            areaState.isFixed = true;
        })
        .catch(err => {
            alert(`Error starting job: ${err.message}`);
            // opzionale: riabilita l’editing se vuoi consentire un nuovo tentativo
            circle.pm.enable();
        });
    });

    delBtn.on('click', (event) => {
        L.DomEvent.stop(event);
        elements.map.removeLayer(circle);
        elements.map.removeLayer(btnGroup);
        const idx = state.previewAreas.findIndex(a => a.circle === circle);
        if (idx !== -1) state.previewAreas.splice(idx, 1);
    });

    // --- Aggiorna posizione bottoni durante le modifiche ---
    const updateButtons = () => {
        if (areaState.isFixed) return;
        const centre = circle.getLatLng();
        updateCoordinates(centre.lat, centre.lng); // Questa riga non serve, la rimuoviamo per pulizia
        const rLatDeg = circle.getRadius() / 111320;
        okBtn.setLatLng([centre.lat + rLatDeg, centre.lng]); // Anche qui, non serve
        delBtn.setLatLng([centre.lat - rLatDeg, centre.lng]); // E qui
    };

    circle.on('drag', () => {
        // Manteniamo la logica di aggiornamento delle coordinate qui
        const centre = circle.getLatLng();
        updateCoordinates(centre.lat, centre.lng);
        const rLatDeg = circle.getRadius() / 111320;
        okBtn.setLatLng([centre.lat + rLatDeg, centre.lng]); // CORRETTO: usa 'lon'
        delBtn.setLatLng([centre.lat - rLatDeg, centre.lng]); // CORRETTO: usa 'lon'
    });

    circle.on('pm:markerdrag', updateButtons);

    // Wait for Geoman to fire the 'pm:enable' event, which signals
    // that the editing handles have been created and are ready.
    circle.on('pm:enable', () => {
        // Now that handles exist, we can style them.
        updateHandleStyles(circle);
    });

    elements.radiusInput.addEventListener('input', () => {
    const preview = state.previewAreas.find(a => !a.isFixed);
    if (preview && preview.circle) {
        const newRadiusMeters = (parseFloat(elements.radiusInput.value) || 0) * 1852;
        if (newRadiusMeters > 0) {
        preview.circle.setRadius(newRadiusMeters);
        }
    }
    });
}

// --- Autocompletamento e Debouncing per il campo ICAO ---
let debounceTimer;

function focusOnSearchTarget({ icao, lat, lon }) {
    const LAT = Number(lat), LON = Number(lon);
    if (!isFinite(LAT) || !isFinite(LON)) return;

    // Aggiorna input
    if (elements.icaoInput) elements.icaoInput.value = icao || elements.icaoInput.value || "";
    if (elements.latInput)  elements.latInput.value  = LAT.toFixed(6);
    if (elements.lonInput)  elements.lonInput.value  = LON.toFixed(6);

    // Centra mappa
    if (elements.map) {
        elements.map.setView([LAT, LON], elements.map.getZoom());
    }

    // Goccia di ricerca + click che crea il cerchio di preview
    try {
        const marker = showSearchMarker(LAT, LON);
        marker.once('click', () => {
            removeSearchMarker();
            createPreviewCircleAt(LAT, LON);
        });
    } catch (e) {
        console.warn('focusOnSearchTarget marker error:', e);
    }
}


elements.icaoInput.addEventListener('input', () => {
    const q = elements.icaoInput.value.trim();
    hideIcaoSuggestions(); // Nascondi prima di tutto

    if (q.length < 2) return; // Non cercare con meno di 2 caratteri

    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(async () => {
        try {
            // Chiama la tua API di ricerca
            const { items } = await api.airportsSearch(q, 10);

            // Callback da eseguire quando l'utente seleziona una voce
            const onSelect = (airport) => {
                clearTimeout(debounceTimer);

                focusOnSearchTarget({
                    icao: airport.icao,
                    lat: airport.lat,
                    lon: airport.lon
                });

                hideIcaoSuggestions();
            };

            showIcaoSuggestions(items, elements.icaoInput, onSelect);

        } catch (e) {
            console.error("Airport search failed:", e);
            hideIcaoSuggestions();
        }
    }, 300); // Debounce di 300ms per evitare di sovraccaricare il server
});

// Aggiungi un listener globale per nascondere la popup quando si clicca fuori
document.addEventListener('click', (e) => {
    if (!e.target.closest(`#${ICAO_SUGGESTION_ID}`) && e.target !== elements.icaoInput) {
        hideIcaoSuggestions();
    }
});

elements.icaoInput.addEventListener('keydown', async (ev) => {
  if (ev.key !== 'Enter') return;
  ev.preventDefault();
  hideIcaoSuggestions();

  const q = ev.target.value.trim();
  if (!q) return;

  try {
    // UNIFICHIAMO IL FLUSSO: usiamo SEMPRE airportsSearch
    const { items } = await airportsSearch(q, 5); // 5 è sufficiente per l'alert

    if (!items || !items.length) {
      alert("Nessun aeroporto trovato per: " + q);
      return;
    }

    // Aggiorna il campo con il codice ICAO (che è il risultato preferito)
    ev.target.value = a.icao || ev.target.value;

    if (items.length > 1) {
      // Se ci sono più risultati, mostriamo i dettagli nell'alert
      const suggested = items.map(i => {
          const iata = i.iata_code ? `(${i.iata_code})` : '';
          const muni = i.municipality ? ` - ${i.municipality}` : '';
          return `${i.icao} ${iata} ${i.name}${muni}`;
      }).join('\n');
      console.info(`Trovati ${items.length} candidati: si usa ${a.icao}. \nAltri: \n${suggested}`);
    }

    focusOnSearchTarget({
        icao: a.icao || ev.target.value,
        lat: a.lat,
        lon: a.lon
    });


  } catch (e) {
    // Questo catch catturerà solo errori 500 o fallimenti di rete, non l'ambiguità.
    console.error(e);
    alert("Lookup fallito: " + (e?.message ?? e));
  }
});


elements.btnFillHoles.addEventListener('click', () => {
    // 1. Disattiva subito il pulsante e applica lo stile "working"
    elements.btnFillHoles.disabled = true;
    elements.btnFillHoles.classList.add('btn-working');

    // Recupera i dati necessari (lo facciamo qui, così se l'utente annulla non succede nulla)
    const bounds = elements.map.getBounds();
    const settings = {
        size: parseInt(elements.sizeInput.value, 10) || 4,
            over: parseInt(elements.overSelect.value, 10) || 1,
            sdwn: parseInt(elements.sdwnSelect.value, 10) || 0,
            server: parseInt(elements.mapServerSelect.value, 10) || state.defaultServerId
    };

    // 2. Chiama l'API per avviare il processo in background
    api.fillHoles(bounds, settings)
    .catch(err => {
        // Se c'è un errore nella chiamata, mostra un alert
        alert(`Error starting the patch process: ${err.message}`);
    })
    .finally(() => {
        // 3. Imposta un timer per riattivare il pulsante dopo 60 secondi
        // Questo avviene sia in caso di successo che di fallimento della chiamata API
        setTimeout(() => {
            elements.btnFillHoles.disabled = false;
            elements.btnFillHoles.classList.remove('btn-working');
        }, 60000); // 60 secondi in millisecondi
    });
});

elements.btnEditPaths.addEventListener('click', () => {
    const isEditing = !elements.outputPathInput.readOnly;

    if (isEditing) {
        // --- Logica per SALVARE ---
        const newPath = elements.outputPathInput.value.trim();
        const newSave = elements.backupPathInput.value.trim();

        if (!newPath || !newSave) {
            alert("Paths cannot be empty.");
            return;
        }

        api.setPaths(newPath, newSave)
        .then(response => {
            if (!response.ok) throw new Error("Server failed to update paths.");
            alert("Paths updated successfully!");
            // Riporta allo stato di sola lettura
            elements.outputPathInput.readOnly = true;
            elements.backupPathInput.readOnly = true;
            elements.btnEditPaths.textContent = "Edit";
            elements.btnEditPaths.style.backgroundColor = "";
        })
        .catch(err => {
            alert(`Error: ${err.message}`);
        });

    } else {
        // --- Logica per MODIFICARE ---
        elements.outputPathInput.readOnly = false;
        elements.backupPathInput.readOnly = false;
        elements.btnEditPaths.textContent = "Save";
        elements.btnEditPaths.style.backgroundColor = "#4CAF50"; // Verde per indicare "conferma"
    }
});

// Toggle "Create Path"
document.getElementById('btn-create-route').addEventListener('click', () => {
  const on = !isManualRouteMode();
  setManualRouteMode(on);
  const b = document.getElementById('btn-create-route');
  b.textContent = on ? 'Create Path (ON)' : 'Create Path';
  b.style.backgroundColor = on ? '#28a745' : '';
  b.style.color = on ? '#fff' : '';
});

elements.btnClearPath.addEventListener('click', () => {
  clearManualRoute();
});

// ------------------------------------------------------------------
// 4. Initialization
// ------------------------------------------------------------------
window.addEventListener('DOMContentLoaded', () => {
    initializeMap();
    if (!state._routeClickBound) {
        elements.map.on('click', (e) => {
            if (!isManualRouteMode()) return;
            addWaypointManual({
                lat: e.latlng.lat,
                lon: e.latlng.lng,
                type: 'Fix',          // o lascia pure null se non ti piace
                source: 'map'
            });
        });
        state._routeClickBound = true;
    }
    populateSdwnDropdown();
    renderSvgButtons(state.resState, handleResFilterClick);
    setupInteractiveSelection();
    toggleMapSelectionMode(state.isMapSelectionMode);

    // 1. Funzione di debounce per il ricaricamento
    const reloadNavaids = () => {
        clearTimeout(navaidsLoadTimer);
        navaidsLoadTimer = setTimeout(() => {
            loadAndDrawNavaids(elements.map); // elementi.map è l'istanza Leaflet
        }, 500); // Ritardo di 500ms
    };

    // 2. Attivazione dei Listener
    elements.map.on('moveend', reloadNavaids);
    elements.map.on('zoomend', reloadNavaids);

    // 3. Primo Caricamento
    reloadNavaids();

    // Primo sync tra DAA e Execute Job
    updateFollowAircraftAvailability();

    api.getSessionInfo().then(info => {
        state.sessionStartTime = new Date(info.startTime);
        console.log("Ora di avvio sessione impostata:", state.sessionStartTime);
    }).catch(err => {
        console.error("Impossibile recuperare l'ora della sessione:", err);
    });

    const handleFilterClick = (filterId) => {
        state.visibilityFilters[filterId] = !state.visibilityFilters[filterId];
        // Ridisegna immediatamente i pulsanti
        renderVisibilityFilters(state.visibilityFilters, handleFilterClick);
        // Forza l'aggiornamento della mappa per applicare il filtro
        mainUpdateLoop();
        reloadNavaids(); // Forza il ricaricamento dei navaid/aeroporti
    };

    // INIZIALIZZA I FILTRI VISIVI
    renderVisibilityFilters(state.visibilityFilters, handleFilterClick);

    // Popola il selettore dei map server al caricamento
    api.getMapServers()
        .then(servers => {
            populateMapServerSelector(servers);
        })
        .catch(err => {
            console.error("Could not load map servers:", err);
            // Opzionale: mostra un errore all'utente o disabilita il selettore
        });
    api.getAppConfig()
        .then(config => {
            console.log("Configurazione ricevuta dal backend:", config);
            // Salva l'ID del server di default nello stato globale
            state.defaultServerId = config.default_server;
            state.lowDetailThreshold = config.low_detail_threshold;
            // Imposta il valore nel selettore a discesa per renderlo visibile all'utente
            elements.mapServerSelect.value = state.defaultServerId;
        })
        .catch(err => {
            console.error("Errore nel caricare la configurazione dell'app:", err);
            // In caso di errore, il default rimarrà 1 (o quello che hai impostato nello stato)
        });
    api.getPaths()
        .then(paths => {
            elements.outputPathInput.value = paths.path;
            elements.backupPathInput.value = paths.save;
        });

    const dropZone = elements.routeDropZone;

    if (dropZone) {
        dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('drag-over');
        });

        dropZone.addEventListener('dragleave', (e) => {
            e.preventDefault();
            dropZone.classList.remove('drag-over');
        });

        dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            dropZone.classList.remove('drag-over');
            const files = e.dataTransfer.files;
            if (files.length > 0) {
                const file = files[0];
                if (file.name.endsWith('.gpx') || file.name.endsWith('.xml')) {
                    const reader = new FileReader();
                    reader.onload = (event) => {
                        route.handleRouteFile(event.target.result, file.name, activeCircles, state);
                    };
                    reader.readAsText(file);
                } else {
                    alert("Per favore, trascina un file .gpx o .xml valido.");
                }
            }
        });
    } else {
        console.warn("routeDropZone non trovato: drag&drop rotta disabilitato.");
    }

    // Gestione della sezione collassabile "Directory Settings"
    if (elements.directorySettingsHeader && elements.directorySettingsContent) {
        elements.directorySettingsHeader.addEventListener('click', () => {
            elements.directorySettingsHeader.classList.toggle('collapsed');
            elements.directorySettingsContent.classList.toggle('collapsed');
        });
        elements.directorySettingsHeader.classList.add('collapsed');
        elements.directorySettingsContent.classList.add('collapsed');
    }

    // Gestione della sezione collassabile "Download Along Route"
    if (elements.routeSettingsHeader && elements.routeSettingsContent) {
        elements.routeSettingsHeader.addEventListener('click', () => {
            elements.routeSettingsHeader.classList.toggle('collapsed');
            elements.routeSettingsContent.classList.toggle('collapsed');
        });
    }

    // Gestore per il salvataggio della traccia
    elements.btnSavePath.addEventListener('click', () => {
        if (state.flightPath.length < 2) {
            alert("Nessun percorso di volo registrato da salvare.");
            return;
        }

        const jsonData = JSON.stringify(state.flightPath, null, 2); // Il 2 formatta il JSON per essere leggibile
        const blob = new Blob([jsonData], { type: 'application/json' });
        const url = URL.createObjectURL(blob);

        const a = document.createElement('a');
        a.href = url;
        const timestamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
        a.download = `flight-path-${timestamp}.json`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    });

    // Salvataggio rotta: usa la rotta manuale se presente, altrimenti la traccia di volo
    elements.btnSaveRoute.addEventListener('click', () => {
        let flightPathForSave = state.flightPath;

        try {
            const manualWps = getManualRouteWaypoints ? getManualRouteWaypoints() : [];

            if (Array.isArray(manualWps) && manualWps.length >= 2) {
                // Costruisco un "flightPath" fittizio dai waypoint manuali.
                // Tutti i punti sono considerati "attivati".
                flightPathForSave = manualWps.map((wp, idx) => ({
                    name: wp.name || `WP${idx + 1}`,
                    lat: wp.lat,
                    lon: wp.lon,
                    altitude_ft: 0,     // se vuoi in futuro puoi mettere una quota reale
                    isActivated: true,
                }));
            }
        } catch (e) {
            console.warn('Impossibile leggere la rotta manuale, uso la traccia di volo:', e);
        }

        openSaveRouteModal(flightPathForSave);
    });

    // Gestore per la pulizia della traccia
    // Pulisce sia la TRACCIA DI VOLO che la ROTTA MANUALE (waypoint)
    elements.btnClearPath.addEventListener('click', () => {
        if (!confirm("Cancellare traccia di volo e rotta manuale?")) return;

        // 1) Traccia di volo (linea blu/arancio registrata dal FGFS)
        state.flightPath = [];
        renderFlightPath(state.flightPath, state.isFlightPathVisible);

        // 2) Rotta manuale (waypoint creati con Create Route)
        if (typeof window.clearManualRoute === 'function') {
            window.clearManualRoute();  // rimuove waypoint + polilinea rotta
        }
    });


    elements.btnTogglePath.addEventListener('click', () => {
        // Inverti lo stato di visibilità
        state.isFlightPathVisible = !state.isFlightPathVisible;
        // Aggiorna il testo del pulsante
        elements.btnTogglePath.textContent = state.isFlightPathVisible ? 'Hide Path' : 'Show Path';
        // Chiama la funzione di disegno per applicare il nuovo stato
        renderFlightPath(state.flightPath, state.isFlightPathVisible);
    });

    // Avvia il loop periodic
    mainUpdateLoop();
});                          // Initial update on startup

// Pollers

startPollers({
  onConnectionState: (data) => {
    const btn = elements.btnConnect;
    btn.classList.remove('active', 'connecting', 'disconnected');
    switch (data.state) {
      case 'connected':
        btn.classList.add('active');
        btn.title = 'FGFS connected';
        state.isConnected = true;
        break;
      case 'connecting':
        btn.classList.add('connecting');
        btn.title = 'FGFS connecting…';
        state.isConnected = false;
        break;
      default:
        btn.classList.add('disconnected');
        btn.title = 'FGFS disconnected';
        state.isConnected = false;
    }
  },
  onCompletedJobs: (n) => {
    console.log(`Completed jobs: ${n}`);
    // puoi anche richiamare checkCompletedJobs() se vuoi aggiornare la mappa
    checkCompletedJobs();
  }
});


// Set up periodic updates
setInterval(checkCompletedJobs, 3000);      // Check completed jobs every 3 seconds
setInterval(mainUpdateLoop, 5000);          // Main update every 5 seconds
setInterval(checkAutoFollow, 2000);  // run every 2 s


