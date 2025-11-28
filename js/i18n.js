/**
 * i18n.js
 * Simple internationalization module for Photoscenery GUI
 */

const i18n = {
    currentLang: 'en',
    translations: {},
    availableLangs: ['en', 'it', 'fr', 'de', 'es', 'zh', 'ja', 'pt', 'ko', 'ar', 'ru'],

    /**
     * Initialize the i18n module
     */
    async init() {
        const savedLang = localStorage.getItem('app_language');
        const browserLang = navigator.language.split('-')[0];
        const defaultLang = this.availableLangs.includes(browserLang) ? browserLang : 'en';

        await this.setLanguage(savedLang || defaultLang);
    },

    /**
     * Set the current language and load translations
     * @param {string} lang - Language code (e.g., 'en', 'it')
     */
    async setLanguage(lang) {
        if (!this.availableLangs.includes(lang)) {
            console.warn(`Language ${lang} not supported, falling back to 'en'`);
            lang = 'en';
        }

        try {
            const response = await fetch(`locales/${lang}.json`);
            if (!response.ok) throw new Error(`Could not load ${lang}.json`);

            this.translations = await response.json();
            this.currentLang = lang;
            localStorage.setItem('app_language', lang);

            // Handle RTL for Arabic
            if (lang === 'ar') {
                document.documentElement.setAttribute('dir', 'rtl');
                document.body.style.textAlign = 'right';
            } else {
                document.documentElement.setAttribute('dir', 'ltr');
                document.body.style.textAlign = 'left';
            }

            this.updatePage();
            console.log(`Language set to ${lang}`);

            // Dispatch event for other components
            window.dispatchEvent(new CustomEvent('languageChanged', { detail: { language: lang } }));

        } catch (error) {
            console.error('Error loading translations:', error);
        }
    },

    /**
     * Get translation for a key
     * @param {string} key - Translation key (dot notation supported)
     * @param {object} params - Parameters for replacement
     * @returns {string} Translated string or key if not found
     */
    t(key, params = {}) {
        const keys = key.split('.');
        let value = this.translations;

        for (const k of keys) {
            if (value && value[k]) {
                value = value[k];
            } else {
                return key; // Return key if translation missing
            }
        }

        // Simple parameter replacement {param}
        if (typeof value === 'string') {
            return value.replace(/{(\w+)}/g, (match, p1) => {
                return params[p1] !== undefined ? params[p1] : match;
            });
        }

        return value;
    },

    /**
     * Update all elements with data-i18n attribute
     */
    updatePage() {
        document.querySelectorAll('[data-i18n]').forEach(element => {
            const key = element.getAttribute('data-i18n');
            const translation = this.t(key);

            // Handle different element types
            if (element.tagName === 'INPUT' && element.type === 'placeholder') {
                element.placeholder = translation;
            } else if (element.tagName === 'IMG') {
                element.alt = translation;
            } else {
                // Check if element has children that shouldn't be overwritten (like icons)
                // For now, we assume simple text replacement or specific structure handling could be added
                // If the element has specific structure, we might need a more complex approach,
                // but for this project innerText/innerHTML is likely fine if we structure keys correctly.
                // To be safe with icons, we can look for specific targets or use innerHTML if the translation contains HTML.

                // If the translation contains HTML tags, use innerHTML, otherwise textContent
                if (/<[a-z][\s\S]*>/i.test(translation)) {
                    element.innerHTML = translation;
                } else {
                    // Preserve children if needed? 
                    // For this simple implementation, we assume the translation covers the whole content 
                    // OR the developer puts the text in a span.
                    element.textContent = translation;
                }
            }

            // Handle tooltips (title attribute)
            if (element.hasAttribute('data-i18n-title')) {
                const titleKey = element.getAttribute('data-i18n-title');
                element.title = this.t(titleKey);
            }
        });

        // Also update elements with just data-i18n-title but no data-i18n
        document.querySelectorAll('[data-i18n-title]:not([data-i18n])').forEach(element => {
            const titleKey = element.getAttribute('data-i18n-title');
            element.title = this.t(titleKey);
        });
    }
};

// Export for module usage
export default i18n;

// Expose to window for non-module access if needed
window.i18n = i18n;
