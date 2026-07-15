import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { Loader2 } from "lucide-react";

// Three.js (like Excalidraw) is heavy -- this module must only ever be reached through
// React.lazy / dynamic import so it stays out of the entry chunk (see
// scripts/check-bundle-size.mjs). It hosts both the interactive spotlight viewer and
// renderModelSnapshot(), the offscreen renderer lib/modelThumbs.ts uses, so both share
// one chunk and one set of scene helpers.

type Stage = {
  renderer: THREE.WebGLRenderer;
  scene: THREE.Scene;
  camera: THREE.PerspectiveCamera;
  dispose: () => void;
};

function createStage(canvas?: HTMLCanvasElement): Stage {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: Boolean(canvas) });
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;

  const scene = new THREE.Scene();
  // RoomEnvironment gives glTF PBR materials studio-style image-based lighting; without
  // an environment map, metallic surfaces render near-black.
  const pmrem = new THREE.PMREMGenerator(renderer);
  const envTexture = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environment = envTexture;

  const camera = new THREE.PerspectiveCamera(45, 1, 0.01, 1000);

  return {
    renderer,
    scene,
    camera,
    dispose: () => {
      envTexture.dispose();
      pmrem.dispose();
      renderer.dispose();
    },
  };
}

// Recenters the model on the origin and places the camera on a slightly raised
// three-quarter view that fits the whole bounding sphere in frame.
function addAndFrame(stage: Stage, model: THREE.Object3D) {
  const box = new THREE.Box3().setFromObject(model);
  const sphere = box.getBoundingSphere(new THREE.Sphere());
  if (!Number.isFinite(sphere.radius) || sphere.radius <= 0) sphere.radius = 1;
  model.position.sub(sphere.center);
  stage.scene.add(model);

  const distance = (sphere.radius / Math.sin(THREE.MathUtils.degToRad(stage.camera.fov / 2))) * 1.15;
  stage.camera.near = distance / 100;
  stage.camera.far = distance * 100;
  stage.camera.position.setFromSphericalCoords(distance, THREE.MathUtils.degToRad(70), THREE.MathUtils.degToRad(35));
  stage.camera.lookAt(0, 0, 0);
  stage.camera.updateProjectionMatrix();
}

function disposeModel(model: THREE.Object3D) {
  model.traverse((child) => {
    if (child instanceof THREE.Mesh) {
      child.geometry.dispose();
      const materials = Array.isArray(child.material) ? child.material : [child.material];
      for (const material of materials) {
        for (const value of Object.values(material)) {
          if (value instanceof THREE.Texture) value.dispose();
        }
        material.dispose();
      }
    }
  });
}

// Offscreen one-shot render for thumbnails: loads the model, renders one square frame
// (transparent background), and returns it as a PNG blob. Everything is disposed before
// resolving, so generating thumbnails for a whole import doesn't accumulate GL contexts.
export async function renderModelSnapshot(src: string, size = 512): Promise<Blob> {
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const stage = createStage(canvas);
  stage.renderer.setSize(size, size, false);
  let model: THREE.Object3D | null = null;
  try {
    const gltf = await new GLTFLoader().loadAsync(src);
    model = gltf.scene;
    addAndFrame(stage, model);
    stage.renderer.render(stage.scene, stage.camera);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
    if (!blob) throw new Error("Could not encode model snapshot");
    return blob;
  } finally {
    if (model) disposeModel(model);
    stage.dispose();
  }
}

// Interactive Sketchfab-style orbit viewer for the focused/spotlight view. Orbit, dolly,
// and pan only respond to gestures that start inside this element -- OrbitControls
// listens on its own canvas, and the wrapper stops pointer events from bubbling up into
// the board's node-drag handlers (the board's capture-phase wheel handler does its own
// [data-model-viewer] check, see Canvas.tsx).
export default function ModelViewer({ src, className }: { src: string; className?: string }) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let disposed = false;
    let frame = 0;
    setStatus("loading");

    const stage = createStage();
    stage.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    stage.renderer.domElement.style.width = "100%";
    stage.renderer.domElement.style.height = "100%";
    stage.renderer.domElement.style.display = "block";
    stage.renderer.domElement.style.touchAction = "none";
    container.appendChild(stage.renderer.domElement);

    const controls = new OrbitControls(stage.camera, stage.renderer.domElement);
    controls.enableDamping = true;

    let needsRender = true;
    controls.addEventListener("change", () => {
      needsRender = true;
    });

    const resize = () => {
      const rect = container.getBoundingClientRect();
      const width = Math.max(1, rect.width);
      const height = Math.max(1, rect.height);
      stage.renderer.setSize(width, height, false);
      stage.camera.aspect = width / height;
      stage.camera.updateProjectionMatrix();
      needsRender = true;
    };
    const observer = new ResizeObserver(resize);
    observer.observe(container);
    resize();

    let model: THREE.Object3D | null = null;
    new GLTFLoader()
      .loadAsync(src)
      .then((gltf) => {
        if (disposed) {
          disposeModel(gltf.scene);
          return;
        }
        model = gltf.scene;
        addAndFrame(stage, model);
        controls.target.set(0, 0, 0);
        controls.update();
        needsRender = true;
        setStatus("ready");
      })
      .catch(() => {
        if (!disposed) setStatus("error");
      });

    // Render on demand: the loop is a cheap no-op unless controls moved (damping included)
    // or something invalidated the frame, so an idle focused model costs ~nothing.
    const loop = () => {
      frame = requestAnimationFrame(loop);
      if (controls.update()) needsRender = true;
      if (needsRender) {
        stage.renderer.render(stage.scene, stage.camera);
        needsRender = false;
      }
    };
    loop();

    return () => {
      disposed = true;
      cancelAnimationFrame(frame);
      observer.disconnect();
      controls.dispose();
      if (model) disposeModel(model);
      stage.dispose();
      stage.renderer.domElement.remove();
    };
  }, [src]);

  return (
    <div
      ref={containerRef}
      data-testid="model-viewer"
      data-model-viewer
      className={`relative h-full w-full ${className ?? ""}`}
      onPointerDown={(event) => event.stopPropagation()}
      onDoubleClick={(event) => event.stopPropagation()}
    >
      {status === "loading" && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center">
          <Loader2 className="h-5 w-5 animate-spin text-[var(--muted)]" />
        </div>
      )}
      {status === "error" && (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center text-xs text-[var(--muted)]">
          Could not load this model
        </div>
      )}
    </div>
  );
}
