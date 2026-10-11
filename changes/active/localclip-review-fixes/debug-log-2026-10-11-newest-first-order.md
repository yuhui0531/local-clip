# LocalClip 0.3.8 (30): newest-first category ordering and recopy promotion

## Summary

In LocalClip 0.3.8 (build 30):
1. **Newest-first batch insertion**: When dragging or assigning multiple clips to a category, the items are prepended in their original selection order (`CategoryOrderTests.newestCategoryBatchFirstAndStable`).
2. **Promotion on external recopy**: When a clip already assigned to one or more categories is re-copied, it is promoted to the top position in every category it belongs to (`CategoryOrderTests.userRecopyPromotesEveryCategory`).
3. **Manual order preserved**: Existing un-affected items retain their relative order.
