/**
 * When a lone pane must keep its tab strip (name card + close).
 *
 * Default: a single pane isn't a "tab", so the header auto-hides. Exceptions
 * force it on so a closeable surface never becomes an unclosable dead zone:
 *  - session tiles (`session-tile:*`) — even before chrome registers
 *  - any closeable `placement: 'main'` contribution
 *  - a collapse tool panel dragged into its own zone
 */

export interface LoneHeaderChrome {
  placement?: string
  uncloseable?: boolean
}

export function forceLoneHeaderForPanes(
  shown: readonly string[],
  chromeOf: (id: string) => LoneHeaderChrome,
  isCollapsePane: (id: string) => boolean,
  /** Fork: sessions visible across the WHOLE layout, not just this zone.
   *  Splitting sessions into separate zones leaves each one "lone", so every
   *  header auto-hides and nothing on screen says which session is which.
   *  With more than one session open, a name card is orientation, not chrome —
   *  so the uncloseable main workspace keeps its header too. One session on
   *  screen stays clean (nothing to disambiguate). */
  openSessionCount = 0
): boolean {
  if (shown.some(id => id.startsWith('session-tile:'))) {
    return true
  }

  if (openSessionCount > 1 && shown.some(id => chromeOf(id).placement === 'main')) {
    return true
  }

  if (
    shown.some(id => {
      const chrome = chromeOf(id)

      return !chrome.uncloseable && chrome.placement === 'main'
    })
  ) {
    return true
  }

  return shown.length === 1 && isCollapsePane(shown[0])
}
