// js/settings.js
import * as api from './api.js';
import { elements } from './ui.js';

// Local state to store paths (since divs don't have .value)
// Local state to store paths (since divs don't have .value)
let currentPaths = {
    path: "",  // Orthophotos
    save: ""   // Orthophotos-saved
};

// Local state for initial paths (to avoid dataset type issues)
let initialPaths = {
    path: "",
    save: ""
};

// Browser state
let currentBrowserTargetKey = ""; // 'path' or 'save'
let currentBrowserSuffix = "";
let currentServerPath = "";

// Modal elements
let dirModal, dirListEl, currentPathEl, previewResultEl, fixedSuffixEl, newFolderInput, btnCreateFolder;

/**
 * Initializes settings logic
 */
export function initSettings() {
    // Cache modal elements
    dirModal = document.getElementById('dirBrowserModal');
    dirListEl = document.getElementById('browserList');
    currentPathEl = document.getElementById('browserCurrentPath');
    previewResultEl = document.getElementById('browserPreviewResult');
    fixedSuffixEl = document.getElementById('browserFixedSuffix');
    newFolderInput = document.getElementById('newFolderInput');
    btnCreateFolder = document.getElementById('btnCreateFolder');
    btnCreateFolder = document.getElementById('btnCreateFolder');

    // 1. Load initial paths
    loadInitialPaths();

    // 2. Click Events on Boxes (open browser)
    elements.outputPathBox.addEventListener('click', () => openDirectoryBrowser('path', 'Orthophotos'));
    elements.backupPathBox.addEventListener('click', () => openDirectoryBrowser('save', 'Orthophotos-saved'));

    // 3. Click Event on "Save & Migrate" button
    elements.btnSavePaths.addEventListener('click', handleSaveAndMigrate);
    document.getElementById('btn-cancel-paths').addEventListener('click', handleCancelChanges);

    // 4. Modal Events (Browser)
    document.getElementById('browserCancelBtn').addEventListener('click', () => dirModal.classList.add('hidden'));
    document.getElementById('browserSelectBtn').addEventListener('click', confirmSelection);
    btnCreateFolder.addEventListener('click', handleCreateFolder);
}

/**
 * Loads paths from server and updates UI
 */
function loadInitialPaths() {
    api.getPaths().then(data => {
        // Store initial values in local state
        initialPaths.path = data.path || "";
        initialPaths.save = data.save || "";

        updatePathState('path', data.path);
        updatePathState('save', data.save);

        // Also update dataset for debugging/reference if needed, but logic relies on initialPaths
        elements.btnSavePaths.dataset.initialPath = initialPaths.path;
        elements.btnSavePaths.dataset.initialSave = initialPaths.save;

        checkButtonState();
    });
}

/**
 * Updates internal state and box text in interface
 */
function updatePathState(key, value) {
    currentPaths[key] = value || "";

    const el = key === 'path' ? elements.outputPathBox : elements.backupPathBox;
    if (el) el.textContent = value || "(Not set)";

    checkButtonState();
}

/**
 * Checks if current paths differ from initial paths and updates button state
 */
function checkButtonState() {
    const oldPath = initialPaths.path;
    const oldSave = initialPaths.save;
    const newPath = currentPaths.path;
    const newSave = currentPaths.save;

    const pathChanged = newPath !== oldPath;
    const saveChanged = newSave !== oldSave;
    const hasChanges = pathChanged || saveChanged;

    elements.btnSavePaths.disabled = !hasChanges;
    elements.btnSavePaths.style.opacity = hasChanges ? "1" : "0.5";
    elements.btnSavePaths.style.cursor = hasChanges ? "pointer" : "not-allowed";

    // Toggle highlighting
    if (pathChanged) {
        elements.outputPathBox.classList.add('modified');
    } else {
        elements.outputPathBox.classList.remove('modified');
    }

    if (saveChanged) {
        elements.backupPathBox.classList.add('modified');
    } else {
        elements.backupPathBox.classList.remove('modified');
    }
}

/**
 * SAVE button logic: launches migration if paths changed
 */
function handleSaveAndMigrate() {
    const newPath = currentPaths.path;
    const newSave = currentPaths.save;

    // Retrieve old paths from local state
    const oldPath = initialPaths.path;
    const oldSave = initialPaths.save;

    // If nothing changed, alert and stop
    if (newPath === oldPath && newSave === oldSave) {
        alert("No changes to save.");
        return;
    }

    if (!newPath || !newSave) {
        alert("Paths cannot be empty.");
        return;
    }

    // --- SMART MESSAGE CONSTRUCTION ---
    let msg = "Confirm configuration update?\n\n";
    let changesDetected = false;

    if (newPath !== oldPath) {
        msg += `👉 MOVE 'Orthophotos' folder:\n   FROM: ${oldPath}\n   TO:   ${newPath}\n\n`;
        changesDetected = true;
    }

    if (newSave !== oldSave) {
        msg += `👉 MOVE 'Orthophotos-saved' folder:\n   FROM: ${oldSave}\n   TO:   ${newSave}\n\n`;
        changesDetected = true;
    }

    if (!changesDetected) {
        // Rare case: paths are equal but maybe it's the first explicit save
        msg += `Orthophotos: ${newPath}\nSaved: ${newSave}`;
    } else {
        msg += "⚠️ Warning: This process will move files. Please wait until finished.";
    }

    if (!confirm(msg)) {
        return;
    }

    if (!confirm(`Confirm migration?\n\nOrthophotos: ${newPath}\nSaved: ${newSave}`)) {
        return;
    }

    // Call API
    api.startPathMigration(newPath, newSave)
        .then(response => {
            if (response.status === 202) {
                // Update "initial" reference values
                initialPaths.path = newPath;
                initialPaths.save = newSave;

                elements.btnSavePaths.dataset.initialPath = newPath;
                elements.btnSavePaths.dataset.initialSave = newSave;

                checkButtonState();

                // Fire event to start monitoring in main.js
                const event = new CustomEvent('migration-started', { detail: { oldPath, newPath } });
                document.dispatchEvent(event);

                // --- REMOVED BLOCKING ALERT ---
                // alert("Migration started in background.");

            } else {
                return response.text().then(t => { throw new Error(t); });
            }
        })
        .catch(err => alert(`Error: ${err.message}`));
}

/**
 * CANCEL button logic: reverts changes to initial values
 */
function handleCancelChanges() {
    // Revert to initial values
    currentPaths.path = initialPaths.path;
    currentPaths.save = initialPaths.save;

    // Update UI text
    elements.outputPathBox.textContent = currentPaths.path || "(Not set)";
    elements.backupPathBox.textContent = currentPaths.save || "(Not set)";

    // Reset button state (disables Save, removes highlights)
    checkButtonState();
}

// --- DIRECTORY BROWSER LOGIC ---

function openDirectoryBrowser(targetKey, suffix) {
    currentBrowserTargetKey = targetKey; // 'path' or 'save'
    currentBrowserSuffix = suffix;
    fixedSuffixEl.textContent = suffix;

    // Calculate starting path from current value
    let startPath = "";
    const currentVal = currentPaths[targetKey];

    if (currentVal && currentVal.includes(suffix)) {
        startPath = currentVal.replace("/" + suffix, "").replace(suffix, "");
    }

    dirModal.classList.remove('hidden');
    loadDirectory(startPath);
}

async function loadDirectory(path) {
    dirListEl.innerHTML = '<div style="padding:10px; color:#666;">Loading...</div>';
    try {
        const data = await api.listServerDirectories(path);
        currentServerPath = data.currentPath;
        currentPathEl.textContent = currentServerPath;
        previewResultEl.textContent = currentServerPath;
        renderDirItems(data.directories);
    } catch (err) {
        dirListEl.innerHTML = `<div style="padding:10px; color:d9534f;">Error: ${err.message}</div>`;
    }
}

function renderDirItems(dirs) {
    dirListEl.innerHTML = '';
    dirs.forEach(dir => {
        const div = document.createElement('div');
        div.className = 'dir-item';
        if (dir.type === 'parent') div.classList.add('parent');

        const icon = dir.type === 'parent' ? '⬆️' : '📁';
        div.innerHTML = `<span class="dir-icon">${icon}</span> <span class="dir-name">${dir.name}</span>`;

        div.onclick = () => loadDirectory(dir.path);
        dirListEl.appendChild(div);
    });
}

function confirmSelection() {
    if (currentBrowserTargetKey && currentServerPath) {
        const sep = (currentServerPath.endsWith('/') || currentServerPath.endsWith('\\')) ? '' : '/';
        const finalPath = `${currentServerPath}${sep}${currentBrowserSuffix}`;

        // Update state and main UI
        updatePathState(currentBrowserTargetKey, finalPath);
    }
    dirModal.classList.add('hidden');
}

async function handleCreateFolder() {
    const name = newFolderInput.value.trim();
    if (!name) { alert("Enter folder name."); return; }
    if (!currentServerPath) return;

    try {
        btnCreateFolder.disabled = true;
        btnCreateFolder.textContent = "...";
        await api.createServerDirectory(currentServerPath, name);
        newFolderInput.value = "";
        await loadDirectory(currentServerPath);
    } catch (err) {
        alert("Failed: " + err.message);
    } finally {
        btnCreateFolder.disabled = false;
        btnCreateFolder.textContent = "+ Create";
    }
}
