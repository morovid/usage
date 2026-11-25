// Keep the page usable without JavaScript. Add a subtle pointer-aware tilt to
// the decorative source card only; no tracking or network requests.
const card = document.querySelector(".source-visual");
const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");

if (card) {
  card.addEventListener("pointermove", (event) => {
    if (motion.matches || !finePointer.matches) return;
    const bounds = card.getBoundingClientRect();
    const x = (event.clientX - bounds.left) / bounds.width - 0.5;
    const y = (event.clientY - bounds.top) / bounds.height - 0.5;
    card.style.transform = `perspective(900px) rotateX(${-y * 5}deg) rotateY(${x * 5}deg) rotate(1deg)`;
  });
  card.addEventListener("pointerleave", () => {
    card.style.removeProperty("transform");
  });
  motion.addEventListener("change", () =>
    card.style.removeProperty("transform"),
  );
}
