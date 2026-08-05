import { describe, expect, it } from 'vitest'

import { forceLoneHeaderForPanes } from './lone-header'

describe('forceLoneHeaderForPanes', () => {
  const chrome =
    (placement?: string, uncloseable = false) =>
    () => ({ placement, uncloseable })

  const noCollapse = () => false

  it('forces a header for session-tile ids even without registered chrome', () => {
    expect(forceLoneHeaderForPanes(['session-tile:abc'], () => ({}), noCollapse)).toBe(true)
  })

  it('forces a header for closeable placement:main panes', () => {
    expect(forceLoneHeaderForPanes(['workspace'], chrome('main', true), noCollapse)).toBe(false)
    expect(forceLoneHeaderForPanes(['some-page'], chrome('main', false), noCollapse)).toBe(true)
  })

  it('forces a header for a lone collapse tool pane', () => {
    expect(
      forceLoneHeaderForPanes(
        ['terminal'],
        () => ({}),
        id => id === 'terminal'
      )
    ).toBe(true)
  })

  it('leaves a lone uncloseable workspace headerless', () => {
    expect(forceLoneHeaderForPanes(['workspace'], chrome('main', true), noCollapse)).toBe(false)
  })

  it('keeps the workspace header when more than one session is on screen', () => {
    // Split into separate zones, each zone's pane is "lone" — without the
    // global count every header hides and nothing names the sessions.
    expect(forceLoneHeaderForPanes(['workspace'], chrome('main', true), noCollapse, 2)).toBe(true)
    // A single session on screen has nothing to disambiguate: stays clean.
    expect(forceLoneHeaderForPanes(['workspace'], chrome('main', true), noCollapse, 1)).toBe(false)
    // Side chrome (files/sessions rails) never gains a header from the count.
    expect(forceLoneHeaderForPanes(['files'], chrome('right', true), noCollapse, 3)).toBe(false)
  })
})
