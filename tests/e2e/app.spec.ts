import { expect, test, type Page } from "@playwright/test";

test.beforeEach(async ({ page }) => {
  await page.goto("/");
});

test("renders the board canvas", async ({ page }) => {
  const header = page.getByRole("banner");
  await expect(header).toHaveAttribute("data-drag-region", "deep");
  await expect(header.getByRole("button", { name: "Close window" })).toBeVisible();
  await expect(header.getByRole("button", { name: "Minimize window" })).toBeVisible();
  await expect(header.getByRole("button", { name: "Maximize window" })).toBeVisible();
  const controls = header.getByTestId("window-controls");
  const platform = await controls.getAttribute("data-platform");
  const controlsBox = await controls.boundingBox();
  const headerBox = await header.boundingBox();
  expect(controlsBox).not.toBeNull();
  expect(headerBox).not.toBeNull();
  if (platform === "mac") {
    expect(controlsBox!.x).toBeLessThan(headerBox!.x + headerBox!.width / 2);
  } else {
    expect(controlsBox!.x).toBeGreaterThan(headerBox!.x + headerBox!.width / 2);
  }
  await expect(header.getByText("Maat", { exact: true })).toBeVisible();
  await expect(page.getByPlaceholder("Search board")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(10);
  await expect(page.locator("article img")).toHaveCount(3);
  const cardClasses = ((await page.locator("article").first().getAttribute("class")) ?? "").split(/\s+/);
  expect(cardClasses).not.toContain("transition");
  expect(cardClasses).toContain("transition-colors");
  const imageClasses = ((await page.locator("article img").first().getAttribute("class")) ?? "").split(/\s+/);
  expect(imageClasses).not.toContain("grayscale");
  await expect(page.getByLabel("Zoom")).toBeVisible();
  await expect(page.getByTestId("canvas-minimap")).toBeVisible();
  await expect(page.getByTitle("Fit content")).toBeVisible();
  await expect(page.getByTitle("Arrange board")).toBeVisible();
  await expect(page.getByRole("button", { name: "New board" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Open folder as board" })).toHaveCount(0);
  await expect(page.getByText("Inspector", { exact: true })).toHaveCount(0);
});

test("search filters assets", async ({ page }) => {
  await page.getByPlaceholder("Search board").fill("font");
  await expect(page.locator("article")).toHaveCount(1);
  await expect(page.getByText("Typeface specimen")).toBeVisible();

  await page.getByPlaceholder("Search board").fill("identity");
  await expect(page.locator("article")).toHaveCount(1);
  await expect(page.getByText("Eagle brand board")).toBeVisible();
});

test("search shortcut focuses and selects the search field", async ({ page }) => {
  const search = page.getByPlaceholder("Search board");
  await search.fill("font");
  await page.getByTestId("maat-canvas").click({ position: { x: 12, y: 12 } });

  await page.keyboard.press("Control+K");
  await expect(search).toBeFocused();

  await page.keyboard.type("identity");
  await expect(search).toHaveValue("identity");
  await expect(page.locator("article")).toHaveCount(1);
  await expect(page.getByText("Eagle brand board")).toBeVisible();
});

test("drawing mode exposes Excalidraw tools without replacing asset mode", async ({ page }) => {
  const drawingSurface = page.getByTestId("drawing-surface");
  await expect(drawingSurface).not.toHaveAttribute("data-drawing", "true");
  await expect(page.getByLabel("Zoom")).toBeVisible();
  await expect(page.getByTestId("canvas-minimap")).toBeVisible();

  await page.getByRole("button", { name: "Draw on canvas" }).click();
  await expect(page.getByRole("button", { name: "Stop drawing" })).toHaveAttribute("aria-pressed", "true");
  await expect(drawingSurface).toHaveAttribute("data-drawing", "true");
  await expect(drawingSurface).toHaveAttribute("aria-hidden", "false");
  await expect(page.getByLabel("Zoom")).toHaveCount(0);
  await expect(page.getByTestId("canvas-minimap")).toHaveCount(0);
  await expect(drawingSurface.locator(".layer-ui__wrapper")).toBeVisible();
  await expect(drawingSurface.getByTestId("toolbar-freedraw")).toBeVisible();
  await expect(drawingSurface.getByTestId("toolbar-rectangle")).toBeVisible();
  await expect(drawingSurface.getByTestId("toolbar-text")).toBeVisible();
  await expect(drawingSurface.getByTestId("toolbar-eraser")).toBeVisible();

  await page.getByRole("button", { name: "Stop drawing" }).click();
  await expect(drawingSurface).not.toHaveAttribute("data-drawing", "true");
  await expect(page.getByRole("button", { name: "Draw on canvas" })).toHaveAttribute("aria-pressed", "false");
  await expect(page.getByLabel("Zoom")).toBeVisible();
  await expect(page.getByTestId("canvas-minimap")).toBeVisible();
});

test("drawing chunk loads lazily: shell paints first, a loading state covers the gap, and no input is dropped", async ({ page }) => {
  // Excalidraw (and its mermaid/katex deps) is split into its own chunk and dynamically imported.
  // Delay that request so the loading state is observable, then confirm it clears once the chunk
  // arrives and drawing still works.
  let releaseChunk: () => void = () => {};
  const chunkGate = new Promise<void>((resolve) => {
    releaseChunk = resolve;
  });
  await page.route("**/DrawingOverlay*", async (route) => {
    await chunkGate;
    await route.continue();
  });
  await page.reload();

  // The board shell (cards, search, toolbar) renders without waiting on the drawing chunk.
  await expect(page.locator("article")).toHaveCount(10);
  await expect(page.getByPlaceholder("Search board")).toBeVisible();

  await page.getByRole("button", { name: "Draw on canvas" }).click();
  await expect(page.getByTestId("drawing-surface-loading")).toBeVisible();
  await expect(page.getByText("Loading drawing tools")).toBeVisible();

  releaseChunk();

  const drawingSurface = page.getByTestId("drawing-surface");
  await expect(drawingSurface.getByTestId("toolbar-rectangle")).toBeVisible();
  await expect(page.getByTestId("drawing-surface-loading")).toHaveCount(0);

  // Drawing works normally once the chunk has resolved — no input was dropped.
  await drawingSurface.getByTestId("toolbar-rectangle").click({ force: true });
  const surfaceBox = await drawingSurface.boundingBox();
  expect(surfaceBox).not.toBeNull();
  await page.mouse.move(surfaceBox!.x + 360, surfaceBox!.y + 260);
  await page.mouse.down();
  await page.mouse.move(surfaceBox!.x + 520, surfaceBox!.y + 380);
  await page.mouse.up();
  await expect.poll(async () => Number(await drawingSurface.getAttribute("data-drawing-elements"))).toBeGreaterThan(0);
});

test("drawings stay board-specific and anchored to canvas zoom", async ({ page }) => {
  const drawingSurface = page.getByTestId("drawing-surface");
  await page.getByRole("button", { name: "Draw on canvas" }).click();
  await drawingSurface.getByTestId("toolbar-rectangle").click({ force: true });

  const surfaceBox = await drawingSurface.boundingBox();
  expect(surfaceBox).not.toBeNull();
  await page.mouse.move(surfaceBox!.x + 360, surfaceBox!.y + 260);
  await page.mouse.down();
  await page.mouse.move(surfaceBox!.x + 520, surfaceBox!.y + 380);
  await page.mouse.up();

  await expect.poll(async () => Number(await drawingSurface.getAttribute("data-drawing-elements"))).toBeGreaterThan(0);
  expect(Number(await drawingSurface.getAttribute("data-excalidraw-scroll-x"))).toBeCloseTo(260 / 0.82, 0);

  await page.getByRole("button", { name: "New board" }).click();
  await page.getByLabel("Board name").fill("Sketch board");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page.getByRole("button", { name: "Sketch board", exact: true })).toBeVisible();
  await expect.poll(async () => Number(await drawingSurface.getAttribute("data-drawing-elements"))).toBe(0);

  await page.getByRole("button", { name: "Maat Studio", exact: true }).click();
  await expect.poll(async () => Number(await drawingSurface.getAttribute("data-drawing-elements"))).toBeGreaterThan(0);

  await page.getByRole("button", { name: "Stop drawing" }).click();
  await page.mouse.move(surfaceBox!.x + surfaceBox!.width / 2, surfaceBox!.y + surfaceBox!.height / 2);
  await page.keyboard.down("Control");
  await page.mouse.wheel(0, -120);
  await page.keyboard.up("Control");
  await expect.poll(async () => Number(await page.getByLabel("Zoom").inputValue())).toBeGreaterThan(100);

  const scale = Number(await drawingSurface.getAttribute("data-viewport-scale"));
  const offsetX = Number(await drawingSurface.getAttribute("data-viewport-offset-x"));
  const scrollX = Number(await drawingSurface.getAttribute("data-excalidraw-scroll-x"));
  expect(scrollX).toBeCloseTo(offsetX / scale, 0);
});

test("clicking a sketch re-enters drawing mode and Delete removes it (not the asset)", async ({ page }) => {
  const surface = page.getByTestId("drawing-surface");
  const sketchCount = () => surface.getAttribute("data-drawing-elements").then(Number);
  const card = await cardCenter(page, "Eagle brand board");

  // Draw a rectangle directly over an asset card.
  await page.getByRole("button", { name: "Draw on canvas" }).click();
  await surface.getByTestId("toolbar-rectangle").click({ force: true });
  await page.mouse.move(card.x - 40, card.y - 30);
  await page.mouse.down();
  await page.mouse.move(card.x + 40, card.y + 30, { steps: 6 });
  await page.mouse.up();
  await expect.poll(sketchCount).toBeGreaterThan(0);
  await page.getByRole("button", { name: "Stop drawing" }).click();
  await expect(page.getByRole("button", { name: "Draw on canvas" })).toBeVisible();

  // Clicking the sketch (over the card) re-enters drawing mode with it selected...
  const cards = await page.locator("article").count();
  await page.mouse.click(card.x, card.y);
  await expect(page.getByRole("button", { name: "Stop drawing" })).toBeVisible();

  // ...and Delete removes the sketch, leaving the asset untouched.
  await page.waitForTimeout(150); // let the programmatic selection settle
  await page.keyboard.press("Delete");
  await expect.poll(sketchCount).toBe(0);
  expect(await page.locator("article").count()).toBe(cards);
});

test("group frames create, rename, move their member cards, and delete", async ({ page }) => {
  const backdrop = page.locator(".board-frame");
  const header = page.locator(".frame-header");

  await page.getByRole("button", { name: "Add group frame" }).click();
  await expect(backdrop).toHaveCount(1);
  await expect(header.locator(".frame-header__label")).toHaveText("Group");

  // Rename via double-click.
  await header.dblclick();
  await page.locator(".frame-header__input").fill("References");
  await page.keyboard.press("Enter");
  await expect(header.locator(".frame-header__label")).toHaveText("References");

  // A card whose center falls inside the frame is a member.
  const fbox = (await backdrop.boundingBox())!;
  const cards = page.locator("article");
  let memberIndex = -1;
  let memberBefore: { x: number; y: number } | null = null;
  for (let i = 0; i < (await cards.count()); i++) {
    const b = await cards.nth(i).boundingBox();
    if (b && b.x + b.width / 2 > fbox.x && b.x + b.width / 2 < fbox.x + fbox.width && b.y + b.height / 2 > fbox.y && b.y + b.height / 2 < fbox.y + fbox.height) {
      memberIndex = i;
      memberBefore = { x: b.x, y: b.y };
      break;
    }
  }
  expect(memberIndex).toBeGreaterThanOrEqual(0);

  // Dragging the header moves the frame and its member together.
  const hb = (await header.boundingBox())!;
  await page.mouse.move(hb.x + hb.width / 2, hb.y + hb.height / 2);
  await page.mouse.down();
  await page.mouse.move(hb.x + hb.width / 2 + 160, hb.y + hb.height / 2 + 100, { steps: 8 });
  await page.mouse.up();
  await expect.poll(async () => Math.round((await backdrop.boundingBox())!.x - fbox.x)).toBeGreaterThan(150);
  // The member card follows the frame (it animates into place, so poll until it settles).
  await expect.poll(async () => Math.round((await cards.nth(memberIndex).boundingBox())!.x - memberBefore!.x)).toBeGreaterThan(150);
  await expect.poll(async () => Math.round((await cards.nth(memberIndex).boundingBox())!.y - memberBefore!.y)).toBeGreaterThan(90);

  await page.getByRole("button", { name: "Delete frame" }).click();
  await expect(backdrop).toHaveCount(0);
});

test("sidebar scopes filter the canvas", async ({ page }) => {
  const sources = page.locator("section").filter({ hasText: "Sources" });
  const source = sources.getByRole("button", { name: /Eagle Library\.library\s*10/i });
  await expect(source).toHaveAttribute("aria-expanded", "true");
  await expect(sources.getByRole("button", { name: /References\s*2/ })).toBeVisible();
  await expect(page.locator("section").filter({ hasText: /^Folders/ })).toHaveCount(0);

  await source.click();
  await expect(source).toHaveAttribute("aria-expanded", "false");
  await expect(sources.getByRole("button", { name: /References\s*2/ })).toHaveCount(0);

  await source.click();
  await expect(source).toHaveAttribute("aria-expanded", "true");
  await expect(sources.getByRole("button", { name: /References\s*2/ })).toBeVisible();

  await sources.getByRole("button", { name: /References\s*2/ }).click();
  await expect(page.locator("article")).toHaveCount(2);
  await expect(page.getByPlaceholder("Search references")).toBeVisible();
  await expect(page.getByText("Eagle brand board")).toBeVisible();
  await expect(page.getByText("Spatial UI still")).toBeVisible();

  await page.getByRole("button", { name: /palette\s*1/i }).click();
  await expect(page.locator("article")).toHaveCount(1);
  await expect(page.getByText("Palette capture")).toBeVisible();

  await page.getByRole("button", { name: /All\s*10/ }).click();
  await expect(page.locator("article")).toHaveCount(10);
});

test("board inbox trash and all scopes switch", async ({ page }) => {
  await page.getByRole("button", { name: /Inbox\s*10/ }).click();
  await expect(page.getByPlaceholder("Search inbox")).toBeVisible();
  await expect(page.getByText("Inbox · 10 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(10);

  await page.getByRole("button", { name: /Trash\s*0/ }).click();
  await expect(page.getByPlaceholder("Search trash")).toBeVisible();
  await expect(page.getByText("Trash · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);

  await page.getByRole("button", { name: /All\s*10/ }).click();
  await expect(page.getByPlaceholder("Search board")).toBeVisible();
  await expect(page.getByText("All · 10 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(10);
});

test("new board creates a blank board", async ({ page }) => {
  await page.getByRole("button", { name: "New board" }).click();
  await expect(page.getByText("Board name", { exact: true })).toBeVisible();
  await page.getByLabel("Board name").fill("Empty Board");
  await page.getByRole("button", { name: "Create" }).click();

  await expect(page.getByRole("button", { name: "Empty Board", exact: true })).toBeVisible();
  await expect(page.getByText("Maat Studio", { exact: true })).toBeVisible();
  await expect(page.getByText("All · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);
  await expect(page.getByText("Drop anything")).toBeVisible();
});

test("theme and zoom controls work", async ({ page }) => {
  await page.getByTitle("Toggle theme").click();
  await expect(page.locator("html")).toHaveClass(/dark/);

  await page.getByLabel("Zoom").fill("150");
  await expect(page.getByLabel("Zoom")).toHaveValue("150");
});

test("asset cards drag without breaking canvas interaction", async ({ page }) => {
  const card = page.getByText("Palette capture").locator("xpath=ancestor::article");
  const before = await card.boundingBox();
  expect(before).not.toBeNull();

  await page.mouse.move(before!.x + before!.width / 2, before!.y + before!.height / 2);
  await page.mouse.down();
  await page.mouse.move(before!.x + before!.width / 2 + 120, before!.y + before!.height / 2 + 60, { steps: 8 });
  await page.mouse.up();

  const after = await card.boundingBox();
  expect(after).not.toBeNull();
  expect(after!.x).toBeGreaterThan(before!.x + 40);
  expect(after!.y).toBeGreaterThan(before!.y + 20);
});

test("middle mouse drag pans the canvas", async ({ page }) => {
  const card = page.getByText("Palette capture").locator("xpath=ancestor::article");
  const before = await card.boundingBox();
  expect(before).not.toBeNull();

  await page.mouse.move(before!.x + before!.width / 2, before!.y + before!.height / 2);
  await page.mouse.down({ button: "middle" });
  await page.mouse.move(before!.x + before!.width / 2 + 140, before!.y + before!.height / 2 + 72, { steps: 8 });
  await page.mouse.up({ button: "middle" });

  const after = await card.boundingBox();
  expect(after).not.toBeNull();
  expect(after!.x).toBeGreaterThan(before!.x + 80);
  expect(after!.y).toBeGreaterThan(before!.y + 40);
});

test("asset click spotlights and canvas click restores", async ({ page }) => {
  const zoom = page.getByLabel("Zoom");
  const startingZoom = Number(await zoom.inputValue());
  const card = page.getByText("Palette capture").locator("xpath=ancestor::article");
  const other = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  const before = await card.boundingBox();
  expect(before).not.toBeNull();

  await page.mouse.click(before!.x + before!.width / 2, before!.y + before!.height / 2);

  await expect(card).toHaveAttribute("data-spotlight", "focused");
  await expect(other).toHaveAttribute("data-spotlight", "dimmed");
  await expect(page.getByTitle("Open inspector")).toBeVisible();
  await expect(page.getByLabel("Zoom")).toHaveCount(0);
  await expect(page.getByTestId("canvas-minimap")).toHaveCount(0);
  await expect.poll(async () => (await card.boundingBox())?.width ?? 0).toBeGreaterThan(before!.width * 2);
  await page.waitForTimeout(260);
  const focusedWidth = (await card.boundingBox())?.width ?? 0;
  await expect(card.getByText("IMAGE")).toBeHidden();

  const canvas = await page.getByTestId("maat-canvas").boundingBox();
  expect(canvas).not.toBeNull();
  await page.mouse.click(canvas!.x + canvas!.width - 24, canvas!.y + 24);

  await expect(card).not.toHaveAttribute("data-spotlight", "focused");
  await expect(page.getByTitle("Open inspector")).toHaveCount(0);
  await expect(page.getByLabel("Zoom")).toBeVisible();
  await expect(page.getByTestId("canvas-minimap")).toBeVisible();
  expect(Number(await zoom.inputValue())).toBe(startingZoom);

  await zoom.fill("150");
  await expect(zoom).toHaveValue("150");
  const zoomedBefore = await card.boundingBox();
  expect(zoomedBefore).not.toBeNull();

  await page.mouse.click(zoomedBefore!.x + zoomedBefore!.width / 2, zoomedBefore!.y + zoomedBefore!.height / 2);
  await expect(card).toHaveAttribute("data-spotlight", "focused");
  await expect.poll(async () => Math.abs(((await card.boundingBox())?.width ?? 0) - focusedWidth)).toBeLessThan(2);
});

test("minimap pans around the canvas", async ({ page }) => {
  const card = page.getByText("Palette capture").locator("xpath=ancestor::article");
  const minimap = await page.getByTestId("canvas-minimap").boundingBox();
  const before = await card.boundingBox();
  expect(minimap).not.toBeNull();
  expect(before).not.toBeNull();
  await expect(card).toBeVisible();

  await page.mouse.click(minimap!.x + minimap!.width - 8, minimap!.y + minimap!.height - 8);
  await expect.poll(async () => (await card.boundingBox())?.x ?? before!.x).toBeLessThan(before!.x - 20);
});

test("wheel pans, ctrl+wheel zooms, and explicit inspector metadata work", async ({ page }) => {
  const zoom = page.getByLabel("Zoom");
  const surface = page.getByTestId("drawing-surface");
  const startingZoom = Number(await zoom.inputValue());
  const canvas = page.getByTestId("maat-canvas");
  const canvasBox = await canvas.boundingBox();
  expect(canvasBox).not.toBeNull();
  const cx = canvasBox!.x + canvasBox!.width / 2;
  const cy = canvasBox!.y + canvasBox!.height / 2;
  await page.mouse.move(cx, cy);

  // Plain wheel pans (viewport offset changes) without zooming.
  const beforeOffsetY = Number(await surface.getAttribute("data-viewport-offset-y"));
  await page.mouse.wheel(0, 240);
  await expect.poll(async () => Number(await surface.getAttribute("data-viewport-offset-y"))).toBeLessThan(beforeOffsetY);
  expect(Number(await zoom.inputValue())).toBe(startingZoom);
  await page.getByTitle("Reset view").click();

  // Ctrl + wheel zooms, centered on the pointer.
  await page.mouse.move(cx, cy);
  await page.keyboard.down("Control");
  await page.mouse.wheel(0, -600);
  await page.keyboard.up("Control");
  await expect.poll(async () => Number(await zoom.inputValue())).toBeGreaterThanOrEqual(200);
  await page.getByTitle("Reset view").click();
  await expect.poll(async () => Number(await zoom.inputValue())).toBe(startingZoom);

  const board = await cardCenter(page, "Eagle brand board");
  await page.mouse.click(board.x, board.y);
  await expect(page.getByText("Inspector", { exact: true })).toHaveCount(0);
  await page.getByTitle("Open inspector").click();
  await expect(page.getByText("identity").nth(1)).toBeVisible();
  await expect(page.getByText("Primary board for the product language.")).toBeVisible();
  await expect(page.getByText("https://example.com/maat")).toBeVisible();
});

test("delete moves selected assets to trash", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await expect(card).toHaveAttribute("data-selected", "true");

  await page.keyboard.press("Delete");
  await expect(page.locator("article")).toHaveCount(9);
  await expect(page.getByText("All · 9 assets")).toBeVisible();

  await page.getByRole("button", { name: /^Trash\s+1$/ }).click();
  await expect(page.getByText("Trash · 1 asset")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(1);
  await expect(page.getByText("Eagle brand board")).toBeVisible();
});

test("trash restore returns an asset to the board", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await page.keyboard.press("Delete");

  await page.getByRole("button", { name: /^Trash\s+1$/ }).click();
  await expect(page.getByText("Trash · 1 asset")).toBeVisible();

  await page.getByText("Eagle brand board").locator("xpath=ancestor::article").click();
  await page.getByRole("button", { name: "Restore selected" }).click();
  await expect(page.getByText("Trash · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);

  await page.getByRole("button", { name: /All\s*10/ }).click();
  await expect(page.locator("article")).toHaveCount(10);
  await expect(page.getByText("Eagle brand board")).toBeVisible();
});

test("delete permanently removes a selected trashed asset", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await page.keyboard.press("Delete");

  await page.getByRole("button", { name: /^Trash\s+1$/ }).click();
  await page.getByText("Eagle brand board").locator("xpath=ancestor::article").click();

  await page.getByRole("button", { name: "Delete selected permanently" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Trash · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);

  // Permanently gone — not restored to the board either.
  await page.getByRole("button", { name: /All\s*9/ }).click();
  await expect(page.locator("article")).toHaveCount(9);
  await expect(page.getByText("Eagle brand board")).toHaveCount(0);
});

test("Delete key in the trash view permanently deletes instead of re-trashing", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await page.keyboard.press("Delete");

  await page.getByRole("button", { name: /^Trash\s+1$/ }).click();
  await page.getByText("Eagle brand board").locator("xpath=ancestor::article").click();

  await page.keyboard.press("Delete");
  await page.getByRole("dialog").getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Trash · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);

  await page.getByRole("button", { name: /All\s*9/ }).click();
  await expect(page.getByText("Eagle brand board")).toHaveCount(0);
});

test("empty trash permanently deletes everything in it", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await page.keyboard.press("Delete");

  await page.getByRole("button", { name: /^Trash\s+1$/ }).click();
  await expect(page.getByText("Trash · 1 asset")).toBeVisible();

  await page.getByRole("button", { name: "Empty trash" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Empty trash" }).click();
  await expect(page.getByText("Trash · 0 assets")).toBeVisible();
  await expect(page.locator("article")).toHaveCount(0);

  await page.getByRole("button", { name: /All\s*9/ }).click();
  await expect(page.getByText("Eagle brand board")).toHaveCount(0);
});

test("removing a source deletes it and everything it imported", async ({ page }) => {
  await expect(page.locator("article")).toHaveCount(10);

  await page.getByRole("button", { name: /^Remove Eagle Library\.library$/ }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Remove" }).click();

  await expect(page.locator("article")).toHaveCount(0);
  await expect(page.getByText("Import an Eagle library or a folder to start.")).toBeVisible();
});

test("double-click renames a board inline", async ({ page }) => {
  await page.getByRole("button", { name: "Maat Studio", exact: true }).dblclick();
  const input = page.getByLabel("Rename Maat Studio");
  await expect(input).toBeVisible();
  await input.fill("Renamed Board");
  await input.press("Enter");

  await expect(page.getByRole("button", { name: "Renamed Board", exact: true })).toBeVisible();
  await expect(page.getByText("Maat Studio", { exact: true })).toHaveCount(0);
});

test("Escape cancels a board rename", async ({ page }) => {
  await page.getByRole("button", { name: "Maat Studio", exact: true }).dblclick();
  const input = page.getByLabel("Rename Maat Studio");
  await input.fill("Should Not Stick");
  await input.press("Escape");

  await expect(page.getByRole("button", { name: "Maat Studio", exact: true })).toBeVisible();
  await expect(page.getByText("Should Not Stick")).toHaveCount(0);
});

test("created boards can be deleted", async ({ page }) => {
  await page.getByRole("button", { name: "New board" }).click();
  await page.getByLabel("Board name").fill("Scratch board");
  await page.getByRole("button", { name: "Create" }).click();
  await expect(page.getByText("Scratch board")).toBeVisible();

  await page.getByLabel("Delete Scratch board").click();
  await page.getByRole("dialog").getByRole("button", { name: "Delete" }).click();
  await expect(page.getByText("Scratch board")).toHaveCount(0);
  await expect(page.getByText("Maat Studio")).toBeVisible();
});

test("window paste and drop import image assets", async ({ page }) => {
  await page.evaluate(() => {
    const data = new DataTransfer();
    data.items.add(new File([new Uint8Array([137, 80, 78, 71])], "pasted-card.png", { type: "image/png" }));
    document.body.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data }));
  });
  await expect(page.locator("article")).toHaveCount(11);
  await expect(page.locator("article").getByText("pasted-card.png", { exact: true })).toBeVisible();

  await page.getByPlaceholder("Search board").evaluate((element) => {
    const data = new DataTransfer();
    data.items.add(new File([new Uint8Array([255, 216, 255, 224])], "focused-paste.jpg", { type: "image/jpeg" }));
    element.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data }));
  });
  await expect(page.locator("article")).toHaveCount(12);
  await expect(page.locator("article").getByText("focused-paste.jpg", { exact: true })).toBeVisible();

  await page.evaluate(() => {
    const data = new DataTransfer();
    data.items.add(new File([new Uint8Array([82, 73, 70, 70])], "dragged-card.webp", { type: "image/webp" }));
    document.body.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data }));
  });
  await expect(page.locator("article")).toHaveCount(13);
  await expect(page.locator("article").getByText("dragged-card.webp", { exact: true })).toBeVisible();

  await page.evaluate(() => {
    const data = new DataTransfer();
    data.setData("text/html", '<img src="https://example.com/pin.webp">');
    document.body.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data }));
  });
  await expect(page.locator("article")).toHaveCount(14);
  await expect(page.locator("article").getByText("pin.webp", { exact: true })).toBeVisible();

  await page.evaluate(() => {
    const data = new DataTransfer();
    data.setData("text/uri-list", "https://example.com/drop.png");
    document.body.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data }));
  });
  await expect(page.locator("article")).toHaveCount(15);
  await expect(page.locator("article").getByText("drop.png", { exact: true })).toBeVisible();
});

test("undecodable (fallback) image import renders a placeholder, not a broken image icon", async ({ page }) => {
  await page.evaluate(() => {
    const data = new DataTransfer();
    data.items.add(new File([new Uint8Array([137, 80, 78, 71])], "corrupt-photo.png", { type: "image/png" }));
    document.body.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: data }));
  });
  await expect(page.locator("article")).toHaveCount(11);
  const card = page.locator("article").filter({ hasText: "corrupt-photo.png" });
  await expect(card).toBeVisible();
  // previewStatus "fallback" must be treated like a non-image kind: no <img> at all
  // (a broken <img> glyph is the exact regression this covers -- see assetPreviewUrl).
  await expect(card.locator("img")).toHaveCount(0);
  await expect(card.getByText("png", { exact: true })).toBeVisible();
});

test("sidebar collapses and expands, giving the canvas the full width", async ({ page }) => {
  const canvas = page.getByTestId("maat-canvas");
  const before = await canvas.boundingBox();
  expect(before).not.toBeNull();

  await page.getByRole("button", { name: "Collapse sidebar" }).click();
  await expect(page.getByRole("button", { name: "New board" })).not.toBeVisible();
  await expect.poll(async () => (await canvas.boundingBox())?.width ?? 0).toBeGreaterThan(before!.width + 200);
  expect(await page.evaluate(() => localStorage.getItem("maat.sidebarOpen"))).toBe("false");

  await page.getByRole("button", { name: "Expand sidebar" }).click();
  await expect(page.getByRole("button", { name: "New board" })).toBeVisible();
  await expect.poll(async () => Math.abs(((await canvas.boundingBox())?.width ?? 0) - before!.width)).toBeLessThan(5);
  expect(await page.evaluate(() => localStorage.getItem("maat.sidebarOpen"))).toBe("true");
});

test("inspector toggle button opens and closes the inspector panel", async ({ page }) => {
  await expect(page.getByText("Inspector", { exact: true })).toHaveCount(0);

  await page.getByRole("button", { name: "Show inspector" }).click();
  await expect(page.getByText("Inspector", { exact: true })).toBeVisible();
  await expect(page.getByText("Select an asset to inspect metadata, source, dimensions, and preview state.")).toBeVisible();
  expect(await page.evaluate(() => localStorage.getItem("maat.inspectorOpen"))).toBe("true");

  await page.getByRole("button", { name: "Hide inspector" }).click();
  await expect(page.getByText("Inspector", { exact: true })).toHaveCount(0);
  expect(await page.evaluate(() => localStorage.getItem("maat.inspectorOpen"))).toBe("false");
});

test("Grid mode arranges assets in a scrollable masonry, and Canvas positions survive the round trip", async ({ page }) => {
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  const before = await card.boundingBox();
  expect(before).not.toBeNull();

  await page.getByRole("tab", { name: "Grid" }).click();
  await expect(page.getByTestId("grid-view")).toBeVisible();
  await expect(page.getByTestId("maat-canvas")).toHaveCount(0);
  await expect(page.locator("article")).toHaveCount(10);
  await expect(page.getByLabel("Zoom")).toHaveCount(0);
  await expect(page.getByTestId("canvas-minimap")).toHaveCount(0);

  await page.getByRole("tab", { name: "Canvas" }).click();
  await expect(page.getByTestId("maat-canvas")).toBeVisible();
  const after = await page.getByText("Eagle brand board").locator("xpath=ancestor::article").boundingBox();
  expect(after).not.toBeNull();
  expect(Math.round(after!.x)).toBe(Math.round(before!.x));
  expect(Math.round(after!.y)).toBe(Math.round(before!.y));
});

test("Infinity mode hides chrome and the spotlighted asset shows its name and size", async ({ page }) => {
  await page.getByRole("tab", { name: "Infinity" }).click();
  await expect(page.getByRole("banner")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "New board" })).not.toBeVisible();
  await expect(page.getByTestId("canvas-minimap")).toHaveCount(0);
  await expect(page.getByLabel("Zoom")).toHaveCount(0);
  await expect(page.getByRole("tab", { name: "Infinity" })).toBeVisible();

  // Use a locator click (not raw coordinates) so Playwright waits for the chrome-collapse layout
  // transition to settle before clicking — the sidebar/header collapse shifts the canvas underneath.
  const card = page.getByText("Eagle brand board").locator("xpath=ancestor::article");
  await card.click();
  await expect(card).toHaveAttribute("data-spotlight", "focused");
  const spotlightMeta = page.getByTestId("spotlight-meta");
  await expect(spotlightMeta.getByText("Eagle brand board", { exact: true })).toBeVisible();
  await expect(spotlightMeta.getByText("Image · 1280 × 860")).toBeVisible();

  await page.keyboard.press("Escape");
  await expect(page.getByRole("banner")).toBeVisible();
  await expect(page.getByRole("tab", { name: "Canvas" })).toHaveAttribute("aria-selected", "true");
});

test("ctrl+wheel over chrome does not trigger browser zoom", async ({ page }) => {
  const zoom = page.getByLabel("Zoom");
  const startingZoom = await zoom.inputValue();

  const defaultPrevented = await page.evaluate(() => {
    return new Promise<boolean>((resolve) => {
      const sidebar = document.querySelector("aside")!;
      const rect = sidebar.getBoundingClientRect();
      window.addEventListener(
        "wheel",
        (event) => resolve(event.defaultPrevented),
        { once: true },
      );
      sidebar.dispatchEvent(
        new WheelEvent("wheel", {
          bubbles: true,
          cancelable: true,
          ctrlKey: true,
          deltaY: -120,
          clientX: rect.x + 20,
          clientY: rect.y + 20,
        }),
      );
    });
  });

  expect(defaultPrevented).toBe(true);
  await expect(zoom).toHaveValue(startingZoom);
});

async function cardCenter(page: Page, name: string) {
  const box = await page.getByText(name).locator("xpath=ancestor::article").boundingBox();
  expect(box).not.toBeNull();
  return { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 };
}
