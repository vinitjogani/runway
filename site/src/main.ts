/**
 * Runway's site entry (index.html). The page is static HTML; this loads its
 * styles and keeps the theme in sync with the OS. Everything works without it.
 */
import './styles/site.css';

import { DARK_SCHEME_QUERY, followTheme, themeStorage } from './theme';

followTheme({ document, storage: themeStorage(window), darkScheme: matchMedia(DARK_SCHEME_QUERY) });
