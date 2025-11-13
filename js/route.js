// Nuovo modulo dedicato alla gestione delle rotte
import * as api from './api.js';
import { airportsSearch, saveRouteGpx } from './api.js';
import { elements, renderWaypointList, drawCircle } from './ui.js';

// Lo stato relativo alla rotta ora vive qui, incapsulato nel suo modulo.
const routeState = {
    waypoints: [],
    isProcessing: false,
    currentSegment: 0,
    currentFileName: '',
    globalState: null,
    currentRoutePolyline: null,
    activeCircles: null,
    manualPointsLayer: null,
    manualPointMarkers: [],
    hoverRing: null
};

export function getManualRouteWaypoints() {
  return routeState.waypoints.slice();   // shallow copy
}

window.jobCompletionCallbacks = new Map(); // Rendi la mappa accessibile globalmente

// --- Funzioni di calcolo Geografico (private del modulo) ---

function haversineDistance(lat1, lon1, lat2, lon2) {
    const R = 3440.065; // Raggio Terra in NM
    const dLat = (lat2 - lat1) * Math.PI / 180;
    const dLon = (lon2 - lon1) * Math.PI / 180;
    const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
              Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
              Math.sin(dLon / 2) * Math.sin(dLon / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    return R * c;
}

function bearing(lat1, lon1, lat2, lon2) {
    const φ1 = lat1 * Math.PI / 180, φ2 = lat2 * Math.PI / 180;
    const λ1 = lon1 * Math.PI / 180, λ2 = lon2 * Math.PI / 180;
    const y = Math.sin(λ2 - λ1) * Math.cos(φ2);
    const x = Math.cos(φ1) * Math.sin(φ2) - Math.sin(φ1) * Math.cos(φ2) * Math.cos(λ2 - λ1);
    const θ = Math.atan2(y, x);
    return (θ * 180 / Math.PI + 360) % 360;
}

function destinationPoint(lat, lon, distance, bearing) {
    const R = 3440.065; // Raggio in NM
    const δ = distance / R;
    const θ = bearing * Math.PI / 180;
    const φ1 = lat * Math.PI / 180, λ1 = lon * Math.PI / 180;
    const φ2 = Math.asin(Math.sin(φ1) * Math.cos(δ) + Math.cos(φ1) * Math.sin(δ) * Math.cos(θ));
    const λ2 = λ1 + Math.atan2(Math.sin(θ) * Math.sin(δ) * Math.cos(φ1), Math.cos(δ) - Math.sin(φ1) * Math.sin(φ2));
    return { lat: φ2 * 180 / Math.PI, lon: λ2 * 180 / Math.PI };
}


// --- Funzioni di Orchestrazione (private del modulo) ---

function waitForSegmentCompletion(segmentJobIds, endWaypointIndex) {
    let completedInSegment = 0;
    const totalInSegment = segmentJobIds.length;

    console.log(`Registrazione di ${totalInSegment} job per la tratta fino a ${routeState.waypoints[endWaypointIndex].name}...`);

    // Per ogni job della tratta, registra una callback
    segmentJobIds.forEach(jobId => {
        window.jobCompletionCallbacks.set(jobId, (completedId) => {
            completedInSegment++;
            console.log(`Job ${completedId} della tratta completato (${completedInSegment}/${totalInSegment}).`);

            // Quando tutti i job della tratta sono completi, passa alla successiva
            if (completedInSegment === totalInSegment) {
                console.log(`Tratta fino a ${routeState.waypoints[endWaypointIndex].name} completata.`);

                routeState.waypoints[endWaypointIndex - 1].status = 'done';
                renderWaypointList(routeState.waypoints, routeState.currentFileName);

                routeState.currentSegment++;
                processNextRouteSegment();
            }
        });
    });
}

function processNextRouteSegment() {
    // --- NUOVA LOGICA DI FINE PROCESSO (CORRETTA) ---
    if (routeState.currentSegment >= routeState.waypoints.length - 1) {
        console.log("Processo rotta completato!");

        // Quando tutti i segmenti sono finiti, segna anche l'ULTIMO waypoint come "done".
        if (routeState.waypoints.length > 0) {
            routeState.waypoints[routeState.waypoints.length - 1].status = 'done';
            renderWaypointList(routeState.waypoints, routeState.currentFileName);
        }
        routeState.isProcessing = false;
        return; // Esci dalla funzione
    }

    const startWp = routeState.waypoints[routeState.currentSegment];
    const endWp = routeState.waypoints[routeState.currentSegment + 1];

    // Segna solo l'inizio e la fine della *nuova* tratta come "processing"
    startWp.status = 'processing';
    endWp.status = 'processing';
    renderWaypointList(routeState.waypoints, routeState.currentFileName);

    const radiusNm = parseFloat(elements.radiusInput.value) || 20;
    const segmentDistance = haversineDistance(startWp.lat, startWp.lon, endWp.lat, endWp.lon);
    const segmentBearing = bearing(startWp.lat, startWp.lon, endWp.lat, endWp.lon);

    // Logica di sovrapposizione: posiziona il prossimo centro a 2/3 del *diametro* (4/3 del raggio)
    // const stepDistance = radiusNm * (4/3);
    const stepDistance = radiusNm
    const numberOfCircles = Math.ceil(segmentDistance / stepDistance);

    const segmentJobIds = [];
    let currentPoint = { lat: startWp.lat, lon: startWp.lon };

    console.log(`Processando tratta: ${startWp.name} -> ${endWp.name}. Distanza: ${segmentDistance.toFixed(1)} NM. Previsti ${numberOfCircles + 1} cerchi.`);

    // Loop per creare tutti i job (Questa parte era già corretta)
    for (let i = 0; i <= numberOfCircles; i++) {
        const centerPoint = (i === 0) ? currentPoint : destinationPoint(currentPoint.lat, currentPoint.lon, stepDistance, segmentBearing);
        currentPoint = centerPoint;

        const jobParams = {
            lat: centerPoint.lat,
            lon: centerPoint.lon,
            radius: radiusNm,
            size: parseInt(elements.sizeInput.value, 10) || 4,
            over: parseInt(elements.overSelect.value, 10) || 1,
            sdwn: parseInt(elements.sdwnSelect.value, 10) || 0,
            server: parseInt(elements.mapServerSelect.value, 10) || routeState.globalState.defaultServerId
        };

        // Chiama l'API e gestisce la promessa
        api.startJob(jobParams).then(jobData => {
            segmentJobIds.push(jobData.jobId);

            console.log(`DEBUG [route.js/processNext]: Chiamata a drawCircle per Job ${jobData.jobId}.`);
            console.log("routeState.activeCircles in questo momento è:", routeState.activeCircles);

            drawCircle(
                jobData.jobId,
                jobData.lat,
                jobData.lon,
                jobParams.radius,
                routeState.activeCircles
            );
            // Solo l'ultimo job ".then" che si risolve chiamerà il waiter
            if (segmentJobIds.length === numberOfCircles + 1) {
                waitForSegmentCompletion(segmentJobIds, routeState.currentSegment + 1);
            }
        }).catch(err => {
             // Gestione errori robusta: se un singolo cerchio fallisce l'avvio, interrompi la catena
             console.error(`Avvio job fallito per il cerchio ${i}: ${err.message}. La catena della rotta è interrotta.`);
             routeState.isProcessing = false;
             // Resetta lo stato visivo a "pending"
             startWp.status = 'pending';
             endWp.status = 'pending';
             renderWaypointList(routeState.waypoints, routeState.currentFileName);
        });
    }
}

/**
 * Funzione principale esportata. Gestisce un file di rotta.
 * È ASINCRONA per permettere la risoluzione degli ICAO durante il parsing.
 * @param {string} fileContent - Il contenuto del file come testo.
 * @param {string} fileName - Il nome del file.
 * @param {Object} activeCircles - Il registro dei cerchi attivi da main.js
 * @param {Object} globalState - L'oggetto 'state' principale da main.js
 */
export async function handleRouteFile(fileContent, fileName, activeCircles, globalState) {

    console.log("DEBUG [route.js/handleRouteFile]: Ho ricevuto:");
    console.log("activeCircles:", activeCircles);
    console.log("globalState:", globalState);

    if (routeState.isProcessing) {
        alert("Un processo di rotta è già in corso.");
        return;
    }

    // Pulisce la polilinea precedente, se esiste
    if (routeState.currentRoutePolyline) {
        elements.map.removeLayer(routeState.currentRoutePolyline);
        routeState.currentRoutePolyline = null;
    }

    // Salva i riferimenti passati da main.js
    routeState.activeCircles = activeCircles;
    routeState.globalState = globalState;

    const parser = new DOMParser();
    const xmlDoc = parser.parseFromString(fileContent, "application/xml");

    let points = xmlDoc.querySelectorAll('rte > rtept'); // GPX
    if (points.length === 0) {
        points = xmlDoc.querySelectorAll('route > wp'); // FGFS XML
    }

    if (points.length < 2) {
        alert("Il file di rotta non è valido o contiene meno di 2 waypoint.");
        return;
    }

    // --- NUOVA LOGICA DI PARSING ASINCRONO ---
    // Usiamo .map per creare un array di "promesse"
    const waypointPromises = Array.from(points).map(async (p) => {
        let lat, lon, name;

        if (p.hasAttribute('lat')) {
            // Caso 1: GPX (ha attributi lat/lon)
            lat = parseFloat(p.getAttribute('lat'));
            lon = parseFloat(p.getAttribute('lon'));
            name = p.querySelector('name')?.textContent || 'WAYPOINT';
        } else {
            // Caso 2: FGFS XML (ha tag figli)
            name = p.querySelector('ident')?.textContent || 'WAYPOINT';
            const latNode = p.querySelector('lat');
            const lonNode = p.querySelector('lon');

            if (latNode && lonNode) {
                // Sottocaso 2a: Waypoint con <lat> e <lon> espliciti
                lat = parseFloat(latNode.textContent);
                lon = parseFloat(lonNode.textContent);
            } else {
                // Sottocaso 2b: Waypoint con <icao> (come la pista di partenza)
                const icaoNode = p.querySelector('icao');
                if (icaoNode) {
                    try {
                        // Usiamo la nostra API per risolvere l'ICAO!
                        const coords = await api.resolveIcao(icaoNode.textContent);
                        lat = coords.lat;
                        lon = coords.lon;
                        // Se l'identificativo è solo un numero di pista, usa l'ICAO come nome
                        if (name.length <= 2) name = icaoNode.textContent;
                    } catch (err) {
                        console.warn(`Impossibile risolvere ICAO ${icaoNode.textContent} dal file di rotta.`, err);
                        lat = NaN; lon = NaN;
                    }
                } else {
                    // Nessun lat/lon E nessun icao. Impossibile processare.
                    lat = NaN; lon = NaN;
                }
            }
        }

        if (!isNaN(lat) && !isNaN(lon)) {
            return { name, lat, lon, status: 'pending' };
        } else {
            return null; // Verrà filtrato via
        }
    });

    // Aspetta che tutte le promesse (incluse le chiamate API per gli ICAO) siano risolte
    const resolvedWaypoints = await Promise.all(waypointPromises);
    routeState.waypoints = resolvedWaypoints.filter(wp => wp !== null); // Rimuove eventuali waypoint falliti

    if (routeState.waypoints.length < 2) {
        alert("Il file di rotta richiede almeno 2 waypoint validi e risolvibili.");
        return;
    }
    // --- FINE NUOVA LOGICA DI PARSING ---

    routeState.isProcessing = true;
    routeState.currentSegment = 0;
    routeState.currentFileName = fileName;

    // Disegna la polilinea (questa logica ora funziona perché aspetta il parsing)
    try {
        const latLngs = routeState.waypoints.map(wp => [wp.lat, wp.lon]);
        const polyline = L.polyline(latLngs, {
            color: '#d9534f', weight: 3, opacity: 0.8, dashArray: '5, 10'
        }).addTo(elements.map);

        routeState.currentRoutePolyline = polyline;
        elements.map.fitBounds(polyline.getBounds().pad(0.1));
    } catch (e) {
        console.error("Errore nel disegnare la polilinea della rotta:", e);
    }

    // Avvia il processo
    renderWaypointList(routeState.waypoints, fileName);
    processNextRouteSegment();
}

/**
 * Mostra una popup semplice (prompt) per dep/arr ICAO,
 * poi chiede al backend di generare il GPX e farlo scaricare.
 */
export async function saveActivatedRouteAsGpx(flightPath) {
    const waypoints = collectActivatedWaypoints(flightPath);

    if (waypoints.length < 2) {
        alert("Seleziona almeno 2 waypoint (clic sui punti arancioni) prima di salvare la rotta.");
        return;
    }

    // prompt super-semplici (poi possiamo fare una modale bella nella UI)
    const dep = prompt("ICAO di PARTENZA (es. LIME) — lascia vuoto se non lo conosci:", "");
    const arr = prompt("ICAO di ARRIVO (es. LIMJ) — lascia vuoto se non lo conosci:", "");

    const payload = { waypoints, dep_icao: (dep || "").trim().toUpperCase(), arr_icao: (arr || "").trim().toUpperCase() };

    try {
        const { filename, gpx } = await saveRouteGpx(payload);

        // Due opzioni: se il backend restituisce 'gpx' testo → scarica subito,
        // altrimenti se restituisce solo 'filename' puoi anche chiedere un GET per download.

        if (gpx) {
            const blob = new Blob([gpx], { type: 'application/gpx+xml' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = filename || `route-${new Date().toISOString().slice(0,19).replace(/[:T]/g,'-')}.gpx`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        } else {
            alert(`Rotta salvata come ${filename}`);
            // opzionale: esporre un endpoint /download?file=...
        }
    } catch (err) {
        alert(`Errore nel salvataggio GPX: ${err.message}`);
    }
}

function toRad(deg){ return deg*Math.PI/180 }
function haversine(lat1, lon1, lat2, lon2){
  const R = 6371e3; // metri
  const φ1 = toRad(lat1), φ2 = toRad(lat2);
  const Δφ = toRad(lat2-lat1), Δλ = toRad(lon2-lon1);
  const a = Math.sin(Δφ/2)**2 + Math.cos(φ1)*Math.cos(φ2)*Math.sin(Δλ/2)**2;
  return 2*R*Math.atan2(Math.sqrt(a), Math.sqrt(1-a)); // metri
}

function collectActivatedWaypoints(flightPath){
  return (flightPath||[])
   .filter(p => p.isActivated)
   .map((p, i) => ({ name: p.name || `WP${i+1}`, lat:p.lat, lon:p.lon, alt_ft: Math.round(p.altitude_ft||0)}));
}

function buildRouteSummary(wps){
  if(wps.length < 2) return "Select at least 2 waypoints.";
  let out = [];
  let total = 0;
  for(let i=0;i<wps.length;i++){
    const {name,lat,lon} = wps[i];
    out.push(`${String(i+1).padStart(2,'0')}  ${name.padEnd(12)}  ${lat.toFixed(5)}, ${lon.toFixed(5)}`);
    if(i>0){
      const d = haversine(wps[i-1].lat, wps[i-1].lon, lat, lon);
      total += d;
      out.push(`    ↳ leg ${i}: ${(d/1000).toFixed(1)} km`);
    }
  }
  out.push(`\nTotal: ${(total/1000).toFixed(1)} km`);
  return out.join('\n');
}

async function suggestAirports(inputEl, ulEl){
  const q = inputEl.value.trim();
  if(!q){ ulEl.classList.add('hidden'); ulEl.innerHTML=''; return; }
  try{
    const {items} = await airportsSearch(q, 10);
    if(!items || !items.length){ ulEl.classList.add('hidden'); ulEl.innerHTML=''; return; }
    ulEl.innerHTML = items.map(a => {
        const city = a.municipality ? ` (${a.municipality})` : '';
        const iata = a.iata_code ? ` ${a.iata_code}` : '';
        return `<li data-icao="${a.icao}"><b>${a.icao}</b>${iata} — ${a.name}${city}</li>`;
    }).join('');
    ulEl.classList.remove('hidden');
    ulEl.onclick = (ev)=>{
      const li = ev.target.closest('li'); if(!li) return;
      inputEl.value = li.dataset.icao; // inseriamo ICAO
      ulEl.classList.add('hidden');
    };
  }catch(e){
    ulEl.classList.add('hidden'); ulEl.innerHTML='';
  }
}

export async function openSaveRouteModal(flightPath){
  const wps = collectActivatedWaypoints(flightPath);
  const modal = document.getElementById('saveRouteModal');
  const depInput = document.getElementById('depInput');
  const arrInput = document.getElementById('arrInput');
  const depSuggest = document.getElementById('depSuggest');
  const arrSuggest = document.getElementById('arrSuggest');
  const summary = document.getElementById('routeSummary');
  const btnOK = document.getElementById('saveRouteConfirm');
  const btnCancel = document.getElementById('saveRouteCancel');

  if (wps.length < 2) {
    alert("Seleziona almeno 2 waypoint (clic blu) prima di salvare.");
    return;
  }

  // riepilogo testuale
  summary.textContent = buildRouteSummary(wps);

  // Primo e ultimo waypoint della rotta come default nei campi
  const firstWp = wps[0];
  const lastWp  = wps[wps.length - 1];
  depInput.value = firstWp && firstWp.name ? firstWp.name : "";
  arrInput.value = lastWp && lastWp.name ? lastWp.name : "";

  modal.classList.remove('hidden');

  const onDep = ()=>suggestAirports(depInput, depSuggest);
  const onArr = ()=>suggestAirports(arrInput, arrSuggest);
  depInput.addEventListener('input', onDep);
  arrInput.addEventListener('input', onArr);

  const cleanup = ()=>{
    depInput.removeEventListener('input', onDep);
    arrInput.removeEventListener('input', onArr);
    modal.classList.add('hidden');
    depSuggest.classList.add('hidden');
    arrSuggest.classList.add('hidden');
  };

  btnCancel.onclick = ()=> cleanup();

  btnOK.onclick = async ()=>{
    const dep = depInput.value.trim().toUpperCase();
    const arr = arrInput.value.trim().toUpperCase();
    try{
      const payload = { waypoints: wps, dep_icao: dep, arr_icao: arr, include_ele: false };
      const { filename, gpx } = await saveRouteGpx(payload);

      const blob = new Blob([gpx], {type:'application/gpx+xml'});
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = filename || 'route.gpx';
      document.body.appendChild(a); a.click(); document.body.removeChild(a);
      URL.revokeObjectURL(url);

      cleanup();
    }catch(e){
      alert("Errore salvataggio GPX: " + e.message);
    }
  };
}

// --- CREA ROTTA MANUALE -------------------------------------------------
let _manualMode = false;

export function setManualRouteMode(on) {
  _manualMode = !!on;
  try {
    const mapEl = elements?.map?.getContainer?.();
    if (mapEl) mapEl.style.cursor = on ? 'crosshair' : '';
  } catch {}
}

export function isManualRouteMode() { return _manualMode; }

export function addWaypointManual({ name, lat, lon, type = null, source = 'map' }) {
  const LAT = Number(lat), LON = Number(lon);
  if (!isFinite(LAT) || !isFinite(LON)) return;

  const wasEmpty = routeState.waypoints.length === 0;

  const idx = routeState.waypoints.length + 1;
  const wpName = (name && String(name).trim()) || `WP${idx}`;

  // 1) aggiorna modello + lista
  routeState.waypoints.push({ name: wpName, lat: LAT, lon: LON, type, status: 'pending' });
  renderWaypointList(routeState.waypoints, routeState.currentFileName || 'Manual route');

  // 2) espandi/scroll pannello
  try {
    const header  = elements.routeSettingsHeader;
    const content = elements.routeSettingsContent;
    if (header && content) {
      header.classList.remove('collapsed');
      content.classList.remove('collapsed');
    }
    const list = elements.routeWaypointList;
    if (list) {
      if (wasEmpty) list.style.outline = '2px solid #007bff';
      list.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      setTimeout(() => { if (wasEmpty) list.style.outline = ''; }, 600);
    }
  } catch {}

  // 3) polilinea
  try {
    const latLngs = routeState.waypoints.map(wp => [wp.lat, wp.lon]);
    if (routeState.currentRoutePolyline) {
      routeState.currentRoutePolyline.setLatLngs(latLngs);
    } else if (elements?.map) {
      routeState.currentRoutePolyline = L.polyline(latLngs, { color:'#4285f4', weight:3, opacity:.9 })
        .addTo(elements.map);
      if (latLngs.length === 1) elements.map.setView(latLngs[0], Math.max(elements.map.getZoom(), 9));
    }
  } catch(e) { console.warn('Polyline update error', e); }

  // 4) puntino blu (unico blocco)
  try {
    if (elements?.map) {
      if (!routeState.manualPointsLayer) {
        routeState.manualPointsLayer = L.layerGroup().addTo(elements.map);
      }
      const dot = L.circleMarker([LAT, LON], {
        radius: 5, color: '#1e90ff', fillColor: '#1e90ff', fillOpacity: 1, weight: 2
      }).addTo(routeState.manualPointsLayer);

      // indice del nuovo WP
      const idxRef = routeState.waypoints.length - 1;
      routeState.manualPointMarkers[idxRef] = dot;

      // hover punto → evidenzia riga & anello rosso
      dot.on('mouseover', () => (window.highlightWaypoint || highlightWaypoint)?.(idxRef, true));
      dot.on('mouseout',  () => (window.highlightWaypoint || highlightWaypoint)?.(idxRef, false));
    }
  } catch(e) { console.warn('Circle marker error', e); }
}

export function removeWaypointAt(i) {
  i = Number(i);
  if (!Number.isInteger(i) || i < 0 || i >= routeState.waypoints.length) return;

  // 1) togli il punto dalla lista in memoria
  routeState.waypoints.splice(i, 1);

  // 1bis) se c'era un anello rosso di hover, rimuovilo
  try {
    if (routeState.hoverRing && elements?.map) {
      elements.map.removeLayer(routeState.hoverRing);
      routeState.hoverRing = null;
    }
  } catch {}

  // 2) ricostruisci PUNTINI BLU + (ri)aggancia hover punto→riga
  try {
    if (elements?.map) {
      if (routeState.manualPointsLayer) {
        elements.map.removeLayer(routeState.manualPointsLayer);
      }
      routeState.manualPointsLayer = L.layerGroup().addTo(elements.map);
      routeState.manualPointMarkers = [];

      routeState.waypoints.forEach((wp, idx) => {
        const dot = L.circleMarker([wp.lat, wp.lon], {
          radius: 5, color: '#1e90ff', fillColor: '#1e90ff', fillOpacity: 1, weight: 2
        });
        // hover punto → evidenzia riga & anello rosso
        dot.on('mouseover', () => (window.highlightWaypoint || window.route?.highlightWaypoint)?.(idx, true));
        dot.on('mouseout',  () => (window.highlightWaypoint || window.route?.highlightWaypoint)?.(idx, false));

        routeState.manualPointsLayer.addLayer(dot);
        routeState.manualPointMarkers[idx] = dot;
      });
    }
  } catch (e) {
    console.warn('Redraw manual points error', e);
  }

  // 3) aggiorna/rimuovi la POLILINEA
  try {
    if (!routeState.waypoints.length) {
      if (routeState.currentRoutePolyline && elements?.map) {
        elements.map.removeLayer(routeState.currentRoutePolyline);
      }
      routeState.currentRoutePolyline = null;
    } else {
      const latLngs = routeState.waypoints.map(wp => [wp.lat, wp.lon]);
      if (routeState.currentRoutePolyline) {
        routeState.currentRoutePolyline.setLatLngs(latLngs);
      } else if (elements?.map) {
        routeState.currentRoutePolyline = L.polyline(latLngs, { color:'#4285f4', weight:3, opacity:.9 })
          .addTo(elements.map);
      }
    }
  } catch(e) {
    console.warn('Polyline redraw error', e);
  }

  // 4) ridisegna la LISTA (con data-index aggiornati)
  renderWaypointList(routeState.waypoints, routeState.currentFileName || 'Manual route');
}

// Svuota la rotta manuale e rimuove la polilinea
export function clearManualRoute() {
  // 1) svuota modello + UI lista
  routeState.waypoints = [];
  renderWaypointList([], '');

  try {
    // 2) rimuovi polilinea
    if (routeState.currentRoutePolyline && elements?.map) {
      elements.map.removeLayer(routeState.currentRoutePolyline);
    }

    // 3) rimuovi layer dei puntini
    if (routeState.manualPointsLayer && elements?.map) {
      elements.map.removeLayer(routeState.manualPointsLayer);
    }

    // 4) rimuovi eventuale anello di evidenziazione
    if (routeState.hoverRing && elements?.map) {
      elements.map.removeLayer(routeState.hoverRing);
    }
  } catch (e) {
    console.warn('clearManualRoute cleanup error', e);
  } finally {
    // 5) azzera i riferimenti
    routeState.currentRoutePolyline = null;
    routeState.manualPointsLayer   = null;
    routeState.manualPointMarkers  = [];   // <-- importante
    routeState.hoverRing           = null; // <-- importante
  }

  // (facoltativo) se vuoi anche “chiudere” il pannello impostazioni rotta:
  try {
    elements.routeSettingsHeader?.classList.add('collapsed');
    elements.routeSettingsContent?.classList.add('collapsed');
  } catch {}
}

export function highlightWaypoint(i, on) {
  i = Number(i);
  const wp = routeState.waypoints?.[i];
  if (!wp || !elements?.map) return;

  // 1) riga lista
  try {
    const li = elements.routeWaypointList?.querySelector(`li[data-index="${i}"]`);
    if (li) li.classList.toggle('wp-hover', !!on);
  } catch {}

  // 2) anello rosso attorno al punto
  try {
    if (routeState.hoverRing) {
      elements.map.removeLayer(routeState.hoverRing);
      routeState.hoverRing = null;
    }
    if (on) {
      routeState.hoverRing = L.circleMarker([wp.lat, wp.lon], {
        radius: 9,          // più grande del pallino blu (5)
        color: '#ff0000',
        weight: 2,
        fillOpacity: 0
      }).addTo(elements.map);
    }
  } catch {}
}

// Calcola la distanza in NM tra ogni coppia consecutiva di waypoint.
// Ritorna un array: [0, d1, d2, ...]
export function computeLegDistancesNM(waypoints) {
  const legs = [];
  for (let i = 0; i < waypoints.length; i++) {
    if (i === 0) {
      legs.push(0);
      continue;
    }
    const a = waypoints[i - 1];
    const b = waypoints[i];
    legs.push(haversineDistance(a.lat, a.lon, b.lat, b.lon));
  }
  return legs;
}
