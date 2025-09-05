// Save as: js/api.js
/**
 * API Communication Module
 *
 * This module contains all functions for communicating with the Julia server.
 * It handles all backend API calls related to:
 * - Job management
 * - FlightGear connection
 * - Map data retrieval
 * - System operations
 */

/**
 * Starts a new processing job with the given parameters
 * @param {Object} params - Job parameters including coordinates and settings
 * @returns {Promise} Resolves with job data or rejects with error
 */
export function startJob(params) {
    console.log("API: Sending job request:", params);
    return fetch('/api/start-job', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(params)
    }).then(res => {
        if (!res.ok) {
            throw new Error(`Server error: ${res.statusText}`);
        }
        return res.json();
    });
}

/**
 * Retrieves session information, like the server start time.
 * @returns {Promise<Object>}
 */
export function getSessionInfo() {
    return fetch('/api/session-info').then(r => r.json());
}

/**
 * Retrieves list of completed job IDs
 * @returns {Promise<Array>} Array of completed job IDs
 */
export function getCompletedJobs() {
    return fetch('/api/completed-jobs').then(r => r.json());
}

/**
 * Establishes connection to FlightGear simulator
 * @param {number} port - FlightGear's telnet port number
 * @returns {Promise} Connection response
 */
export function connectToFgfs(port) {
    console.log(`API: Requesting FGFS connection on port ${port}`);
    return fetch('/api/connect', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ port })
    });
}

/**
 * Disconnects from FlightGear simulator
 * @returns {Promise} Disconnection response
 */
export function disconnectFromFgfs() {
    console.log("API: Requesting FGFS disconnection.");
    return fetch('/api/disconnect', { method: 'POST' });
}

/**
 * Gets current FlightGear connection status
 * @returns {Promise<Object>} Contains connection status and aircraft position
 */
export function getFgfsStatus() {
    return fetch('/api/fgfs-status').then(r => r.json());
}

/**
 * Retrieves map coverage data
 * @returns {Promise<Array>} Array of map coverage areas
 */
export function getCoverageData() {
    return fetch('coverage.json').then(r => r.ok ? r.json() : []);
}

/**
 * Generates URL for tile preview image
 * @param {string} id - Tile identifier
 * @param {number} [width=512] - Preview image width in pixels
 * @returns {string} Preview image URL
 */
export function getTilePreview(id, width = 512) {
    return `/preview?id=${id}&w=${width}`;
}

/**
 * Sends shutdown command to the server
 * @returns {Promise} Shutdown response
 */
export function shutdownServer() {
    console.log("API: Sending shutdown command.");
    return fetch('/api/shutdown', { method: 'POST' });
}

/**
 * Resolves an ICAO code to geographic coordinates via the backend.
 * @param {string} icao - The ICAO code to resolve.
 * @returns {Promise<Object>} A promise that resolves with {lat, lon}.
 */
export function resolveIcao(icao) {
    return fetch(`/api/resolve-icao?icao=${encodeURIComponent(icao)}`)
    .then(res => {
        if (!res.ok) {
            return res.text().then(text => { throw new Error(text) });
        }
        return res.json();
    });
}

/**
 * Returns the current FGFS connection state (disconnected | connecting | connected)
 * @returns {Promise<string>}
 */
export function getFgfsConnectionState() {
    return fetch('/api/connection-state')
    .then(r => r.json())
    .then(obj => obj.state);
}

/**
 * Asks the backend to find and download missing tiles within the given map bounds.
 * @param {Object} bounds - Leaflet map bounds { _southWest, _northEast }.
 * @param {Object} settings - Current job settings (size, sdwn, over).
 * @returns {Promise}
 */
export function fillHoles(bounds, settings) {
    const payload = {
        bounds: {
            south: bounds._southWest.lat,
            west:  bounds._southWest.lng,
            north: bounds._northEast.lat,
            east:  bounds._northEast.lng
        },
        settings: settings
    };
    console.log("API: Sending fill holes request:", payload);
    return fetch('/api/fill-holes', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(payload)
    }).then(res => {
        if (!res.ok) throw new Error(`Server error: ${res.statusText}`);
        return res.json();
    });
}

/**
 * Retrieves the list of available map servers from the backend.
 * @returns {Promise<Array>} A promise that resolves with an array of server objects.
 */
export function getMapServers() {
    return fetch('/api/map-servers').then(r => r.json());
}

// Aggiungi questa funzione
export function getAppConfig() {
    return fetch('/api/app-config').then(r => r.json());
}

export function getPaths() {
    return fetch('/api/paths').then(r => r.json());
}

export function setPaths(path, save) {
    return fetch('/api/paths', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ path, save })
    });
}
