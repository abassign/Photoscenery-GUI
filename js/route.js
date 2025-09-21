// Nuovo modulo dedicato alla gestione delle rotte
import * as api from './api.js';
import { elements, renderWaypointList, drawCircle } from './ui.js';

// Lo stato relativo alla rotta ora vive qui, incapsulato nel suo modulo.
const routeState = {
    waypoints: [],
    isProcessing: false,
    currentSegment: 0,
    currentFileName: '',
    globalState: null,
    currentRoutePolyline: null,
    activeCircles: null
};

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

// ▼▼▼ CHECK POINT 3: COSA STIAMO USANDO? ▼▼▼
console.log(`DEBUG [route.js/processNext]: Chiamata a drawCircle per Job ${jobData.jobId}.`);
console.log("routeState.activeCircles in questo momento è:", routeState.activeCircles);
// ▲▲▲ FINE CHECK POINT ▲▲▲

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

// ▼▼▼ CHECK POINT 2: COSA ABBIAMO RICEVUTO? ▼▼▼
console.log("DEBUG [route.js/handleRouteFile]: Ho ricevuto:");
console.log("activeCircles:", activeCircles);
console.log("globalState:", globalState);
// ▲▲▲ FINE CHECK POINT ▲▲▲


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
