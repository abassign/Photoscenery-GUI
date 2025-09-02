// Save as: js/main.js (final version)
import * as api from './api.js';
import {
    elements,
    initializeMap,
    updateMapCoverage,
    updateAircraftPosition,
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
} from './ui.js';

// ---------- DEBUG SWITCH ----------
window.DEBUG_FGFS = true;        // flip to false to silence
const log = (...a) => window.DEBUG_FGFS && console.log('[DEBUG-JS]', ...a);

// --- Aircraft-auto-queue settings ---
const RADIUS_AROUND_AC = 20;   // NM of each circle
const OVERLAP_FACTOR   = 0.4;  // ⅔ diameter offset
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
    daaArmed: false                 // isteresi: diventa true solo dopo essere entrati sotto ARM_TH
};

const activeCircles = {};           // Stores active job circles on the map
let pendingCircle = null;           // Temporary Leaflet circle object

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
            // POI salva la rotta nello stato globale
            state.currentHeading = data.heading;
        });
        updateFollowAircraftAvailability();
    }

    api.getCoverageData().then(coverageData => {
        const allowedResolutions = new Set(
            state.resState.map((active, i) => active ? i : -1).filter(i => i !== -1)
        );
        updateMapCoverage(coverageData, allowedResolutions, state.currentOpacity, state.dateFilterIndex, state.sessionStartTime);
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
 * Draws a circle on the map for a job
 * @param {string} jobId - Unique job identifier
 * @param {number} lat - Latitude coordinate
 * @param {number} lon - Longitude coordinate
 * @param {number} radiusKm - Circle radius in kilometers
 */
function drawCircle(jobId, lat, lon, radiusKm) {
    if (activeCircles[jobId]) return;

    const circle = L.circle([lat, lon], {
        radius: radiusKm * 1852,
        color: '#00cc00',
        fillColor: '#00cc00',
        fillOpacity: 0.15,
        weight: 1.5
    }).addTo(elements.map);

    activeCircles[jobId] = circle;
    state.lastDaaCenterPoint = circle.getLatLng();
    state.lastDaaCircleLayer = circle;
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
    if (state.followAircraftActive) {
        return; // Esce immediatamente dalla funzione.
    }
    api.getCompletedJobs().then(ids => {
        if (ids.length) {
            ids.forEach(id => clearCircle(id));        // remove green circle
            processQueueSequentially();                // start next preview → green
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
            over: 2,
            size: parseInt(elements.sizeInput.value, 10) || 4,
            sdwn: parseInt(elements.sdwnSelect.value, 10) || 0,
            server: parseInt(elements.serverSelect.value, 10) || 1,
            mode: 'daa'
        };

        const circle = L.circle([ahead.lat, ahead.lon], {
            radius: radiusNm * 1852,
            color: '#00cc00',
            fillColor: '#00cc00',
            fillOpacity: 0.15,
            weight: 1.5
        }).addTo(elements.map);

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
    if (!state.followAircraftActive) return;
    if (state.isAutoJobPending) { log('DAA skip: pending'); return; }
    if (!throttleOk) { log('DAA skip: throttle'); return; }

    api.getFgfsStatus().then(data => {
        if (!data.active) return;

        // Usa prima il layer salvato; se manca, prova con l'ID
        const lastCircle =
        state.lastDaaCircleLayer ||
        (state.lastDaaCircleId ? activeCircles[state.lastDaaCircleId] : null);

        if (!lastCircle) {
            if (state.lastDaaCenterPoint) {
                const acPos  = L.latLng(data.lat, data.lon);
                const radius = (parseFloat(elements.radiusInput.value) || 20) * 1852; // metri
                const distToCtr = acPos.distanceTo(state.lastDaaCenterPoint);
                if (distToCtr > radius * OVERLAP_FACTOR) {
                    log('DAA Fallback trigger (no layer, using saved centre)');
                    state.isAutoJobPending = true;
                    startAutomaticFollowJob();
                }
            }
            return;
        }

        const acPos   = L.latLng(data.lat, data.lon);
        const radius  = lastCircle.getRadius();                    // metri
        const centre  = state.lastDaaCenterPoint || lastCircle.getLatLng();

        const distToCtr = acPos.distanceTo(centre);
        const FIRE_TH   = radius * OVERLAP_FACTOR;       // es. 0.4·R
        const ARM_TH    = radius * (OVERLAP_FACTOR * 0.7); // isteresi: es. 0.28·R

        // 1) Se NON armati, armiamoci solo quando entriamo “sotto” ARM_TH
        if (!state.daaArmed) {
            if (distToCtr <= ARM_TH) {
                state.daaArmed = true;
                log('DAA armed: dist=', Math.round(distToCtr), 'arm=', Math.round(ARM_TH));
            }
            return; // fino a quando non siamo armati, niente trigger
        }
        // 2) Se armati, spara quando torniamo SOPRA FIRE_TH (e throttle OK)
        if (distToCtr >= FIRE_TH) {
            log('DAA fire: dist=', Math.round(distToCtr), 'fire=', Math.round(FIRE_TH));
            state.isAutoJobPending = true;
            startAutomaticFollowJob();
            // disarma per il ciclo successivo (verrà riaramato quando ci si riavvicina)
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

// ---------- Traffic-light poller ----------
import {getFgfsConnectionState} from './api.js';  // Tenere o togliere ?
// Sostituisci il vecchio poller alla fine di main.js con questo
setInterval(() => {
    fetch('/api/connection-state')
    .then(r => {
        if (!r.ok) { throw new Error(`Il server ha risposto ${r.status}`); }
        return r.json();
    })
    .then(response => { // <<< CORREZIONE CHIAVE: rinominata la variabile per evitare conflitti
        const btn = elements.btnConnect;
        const connectionStatus = response.state; // Estraiamo lo stato (es. "connecting")

    // Rimuove tutte le classi di stato precedenti per una gestione pulita
    btn.classList.remove('active', 'connecting', 'disconnected');

    switch (connectionStatus) {
        case 'connected':
            btn.classList.add('active');
            btn.title = 'FGFS connected';
            // Ora modifichiamo l'oggetto globale 'state' corretto
            state.isConnected = true;
            break;
        case 'connecting':
            btn.classList.add('connecting');
            btn.title = 'FGFS connecting…';
            // Ora modifichiamo l'oggetto globale 'state' corretto
            state.isConnected = false;
            break;
        default: // 'disconnected'
            btn.classList.add('disconnected');
            btn.title = 'FGFS disconnected';
            // Ora modifichiamo l'oggetto globale 'state' corretto
            state.isConnected = false;
    }
    })
    .catch((err) => {
        console.error("Impossibile ottenere lo stato della connessione:", err);
        const btn = elements.btnConnect;
        btn.classList.remove('active', 'connecting');
        btn.classList.add('disconnected');
        state.isConnected = false;
    });
}, 1500);

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
            server: parseInt(elements.serverSelect.value, 10) || 1,
            mode: 'manual'
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
    circle.on('pm:markerdrag', updateButtons);

    // Wait for Geoman to fire the 'pm:enable' event, which signals
    // that the editing handles have been created and are ready.
    circle.on('pm:enable', () => {
        // Now that handles exist, we can style them.
        updateHandleStyles(circle);
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
        }
    });
}

elements.icaoInput.addEventListener('keydown', (e) => {
    // Controlla se il tasto premuto è 'Invio' e se il campo non è vuoto
    if (e.key === 'Enter' && elements.icaoInput.value.trim() !== '') {
        e.preventDefault(); // Impedisce l'invio di un form (comportamento di default)

    const icao = elements.icaoInput.value.trim().toUpperCase();

    // Chiama l'API per ottenere le coordinate
    api.resolveIcao(icao)
    .then(coords => {
        // Successo! Crea il cerchio di anteprima con le coordinate ricevute
        createPreviewCircleAt(coords.lat, coords.lon);

        // Centra la mappa sulla nuova posizione
        elements.map.setView([coords.lat, coords.lon], 10);
    })
    .catch(err => {
        // Gestisce l'errore se l'ICAO non viene trovato
        alert(`Error: Could not resolve ICAO '${icao}'.`);
    });
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
                                       sdwn: parseInt(elements.sdwnSelect.value, 10) || 0
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


// ------------------------------------------------------------------
// 4. Initialization
// ------------------------------------------------------------------
window.addEventListener('DOMContentLoaded', () => {
    initializeMap();
    populateSdwnDropdown();
    renderSvgButtons(state.resState, handleResFilterClick);
    setupInteractiveSelection();
    toggleMapSelectionMode(state.isMapSelectionMode);

    // Primo sync tra DAA e Execute Job
    updateFollowAircraftAvailability();

    api.getSessionInfo().then(info => {
        state.sessionStartTime = new Date(info.startTime);
        console.log("Ora di avvio sessione impostata:", state.sessionStartTime);
    }).catch(err => {
        console.error("Impossibile recuperare l'ora della sessione:", err);
    });

    // Avvia il loop periodic
    mainUpdateLoop();
});                          // Initial update on startup

// Set up periodic updates
setInterval(checkCompletedJobs, 3000);      // Check completed jobs every 3 seconds
setInterval(mainUpdateLoop, 5000);          // Main update every 5 seconds
setInterval(checkAutoFollow, 2000);  // run every 2 s


