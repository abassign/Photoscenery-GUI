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
