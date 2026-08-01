return {
    -- 0 = unlimited editions per card
    max_editions = 0,
    -- allow the same edition twice (2x Polychrome = X1.5 * X1.5)
    allow_duplicates = false,
    -- blend every edition's shader so all of them stay visible at once.
    -- false = vanilla behaviour, only the last shader shows.
    blend_overlays = true,
}
