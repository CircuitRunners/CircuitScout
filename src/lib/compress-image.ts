/**
 * Downscale and re-encode before upload.
 *
 * A modern phone camera produces 4-8MB per shot. Fifty pits on venue wifi is
 * hundreds of megabytes, and the bandwidth is shared with everyone else in the
 * building. 1280px at 75% quality is plenty for identifying a robot.
 */
export async function compressImage(
  file: File,
  maxDimension = 1280,
  quality = 0.75,
): Promise<Blob> {
  if (!file.type.startsWith("image/")) return file;

  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    return file; // Unsupported format: upload as-is rather than losing the photo.
  }

  const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  const context = canvas.getContext("2d");
  if (!context) return file;
  context.drawImage(bitmap, 0, 0, width, height);
  bitmap.close();

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/jpeg", quality),
  );

  return blob ?? file;
}
