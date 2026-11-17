/**
 * Keeps the page's theme in step after first paint.
 *
 * The inline pre-paint script in index.html resolves `data-theme` once; this
 * follows the OS while the preference is "system" and picks up a choice made
 * in another tab. The preference is a JSON-encoded value under `runway:theme`.
 */

export type ThemePreference = 'system' | 'light' | 'dark';
export type Theme = 'light' | 'dark';

export const THEME_STORAGE_KEY = 'runway:theme';
export const DARK_SCHEME_QUERY = '(prefers-color-scheme: dark)';

const PREFERENCES: readonly ThemePreference[] = ['system', 'light', 'dark'];

/** The part of `Storage` the theme reads (so an in-memory stand-in fits). */
export type ThemeStorage = Pick<Storage, 'getItem'>;

export interface ThemeEnvironment {
  document: Document;
  /** `null` where storage is blocked (merely touching it throws). */
  storage: ThemeStorage | null;
  /** `(prefers-color-scheme: dark)` media query. */
  darkScheme: MediaQueryList;
}

/** `localStorage`, or `null` where the browser blocks it. */
export function themeStorage(window: Window): ThemeStorage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function readThemePreference(storage: ThemeStorage | null): ThemePreference {
  try {
    const value: unknown = JSON.parse(storage?.getItem(THEME_STORAGE_KEY) ?? '"system"');
    return PREFERENCES.find((preference) => preference === value) ?? 'system';
  } catch {
    return 'system';
  }
}

export function resolveTheme(preference: ThemePreference, systemPrefersDark: boolean): Theme {
  if (preference !== 'system') return preference;
  return systemPrefersDark ? 'dark' : 'light';
}

/**
 * Sets `data-theme` and syncs `<meta name="theme-color">` (browser UI) with
 * the page canvas token, so a choice made in an app wins over the OS one.
 */
export function applyTheme(document: Document, theme: Theme): void {
  const root = document.documentElement;
  root.dataset.theme = theme;
  const canvas = document.defaultView?.getComputedStyle(root).getPropertyValue('--color-bg-subtle').trim();
  if (!canvas) return;
  for (const meta of document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]')) {
    meta.content = canvas;
  }
}

/**
 * Applies the resolved theme now and whenever the OS scheme or the stored
 * preference changes.
 *
 * @returns a function that removes every listener.
 */
export function followTheme(env: ThemeEnvironment): () => void {
  const { document, storage, darkScheme } = env;
  const sync = (): void => applyTheme(document, resolveTheme(readThemePreference(storage), darkScheme.matches));
  const onStorage = (event: StorageEvent): void => {
    if (event.key === THEME_STORAGE_KEY) sync();
  };

  const window = document.defaultView;
  darkScheme.addEventListener('change', sync);
  window?.addEventListener('storage', onStorage);
  sync();

  return () => {
    darkScheme.removeEventListener('change', sync);
    window?.removeEventListener('storage', onStorage);
  };
}
