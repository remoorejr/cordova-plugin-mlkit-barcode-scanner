package com.mobisys.cordova.plugins.mlkit.barcode.scanner;

import android.Manifest;
import android.annotation.SuppressLint;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Point;
import android.graphics.PointF;
import android.graphics.PixelFormat;
import android.graphics.PorterDuff;
import android.graphics.RectF;
import android.os.Bundle;

import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.widget.ImageButton;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.camera.core.AspectRatio;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.LiveData;

import com.google.android.gms.common.api.CommonStatusCodes;
import com.google.android.gms.tasks.OnCompleteListener;
import com.google.android.gms.tasks.OnFailureListener;
import com.google.android.gms.tasks.OnSuccessListener;
import com.google.android.gms.tasks.Task;
import com.google.android.material.snackbar.Snackbar;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.barcode.BarcodeScanner;
import com.google.mlkit.vision.barcode.BarcodeScannerOptions;
import com.google.mlkit.vision.barcode.BarcodeScanning;
import com.google.mlkit.vision.common.InputImage;
import com.mobisys.cordova.plugins.mlkit.barcode.scanner.utils.BitmapUtils;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class CaptureActivity extends AppCompatActivity implements SurfaceHolder.Callback {

  public Integer BarcodeFormats;
  public double DetectorSize = .5;
  public double DetectorHeight = 0; // 0 = same as DetectorSize (square)

  public static final String BarcodeFormat = "MLKitBarcodeFormat";
  public static final String BarcodeType = "MLKitBarcodeType";
  public static final String BarcodeValue = "MLKitBarcodeValue";

  private ListenableFuture<ProcessCameraProvider> cameraProviderFuture;
  private ExecutorService executor = Executors.newSingleThreadExecutor();
  private PreviewView mCameraView;
  private SurfaceHolder holder;
  private SurfaceView surfaceView;
  private Paint _TargetPaint;
  private Paint _HitPaint;
  private Paint _SelectedPaint;
  private Paint _SelectedFillPaint;
  private Paint _LabelPaint;
  private Paint _LabelBackgroundPaint;
  private float _Density = 1f;

  private static final int RC_HANDLE_CAMERA_PERM = 2;
  private ImageButton _TorchButton;
  private Camera camera;

  private boolean _CaptureButtonMode = false;
  private volatile boolean _CaptureRequested = false;
  private boolean _HighlightMode = false;
  private boolean _RotateCamera = false;
  private boolean _Finished = false;

  /** A barcode detected inside the target area, in overlay (view) coordinates. */
  private static class Hit {
    Barcode barcode;
    String key;
    String value;
    PointF[] points;
    RectF bounds;
  }

  private final List<Hit> _Hits = new ArrayList<>();
  private Hit _Selected;
  private String _UserSelectedKey;

  private ScaleGestureDetector _ScaleGestureDetector;
  private GestureDetector _GestureDetector;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    setContentView(getResources().getIdentifier("capture_activity", "layout", getPackageName()));

    // Create the bounding box
    surfaceView = findViewById(getResources().getIdentifier("overlay", "id", getPackageName()));
    surfaceView.setZOrderOnTop(true);

    holder = surfaceView.getHolder();
    holder.setFormat(PixelFormat.TRANSPARENT);
    holder.addCallback(this);

    // read parameters from the intent used to launch the activity.
    BarcodeFormats = getIntent().getIntExtra("BarcodeFormats", 1234);
    DetectorSize = getIntent().getDoubleExtra("DetectorSize", .5);

    if (DetectorSize <= 0 || DetectorSize >= 1) { // setting boundary detectorSize must be between 0 to 1.
      DetectorSize = 0.5;
    }

    DetectorHeight = getIntent().getDoubleExtra("DetectorHeight", 0);
    if (DetectorHeight <= 0 || DetectorHeight > 2) { // 0 (or invalid) means: same as DetectorSize
      DetectorHeight = 0;
    }

    _HighlightMode = getIntent().getBooleanExtra("HighlightBarcode", false);
    _RotateCamera = getIntent().getBooleanExtra("RotateCamera", false);
    createPaints();

    int rc = ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA);

    if (rc == PackageManager.PERMISSION_GRANTED) {
      // Start Camera
      startCamera();
    } else {
      requestCameraPermission();
    }

    // Highlight mode needs a button to confirm the selected barcode.
    _CaptureButtonMode = _HighlightMode || getIntent().getBooleanExtra("CaptureButton", false);
    if (_CaptureButtonMode) {
      View captureButton = findViewById(getResources().getIdentifier("capture_button", "id", getPackageName()));
      captureButton.setVisibility(View.VISIBLE);
      captureButton.setOnClickListener(new View.OnClickListener() {
        @Override
        public void onClick(View v) {
          if (_HighlightMode) {
            if (_Selected != null) {
              deliverBarcode(_Selected.barcode);
            } else {
              showNoBarcodeFound();
            }
          } else {
            _CaptureRequested = true;
          }
        }
      });
    }

    _GestureDetector = new GestureDetector(this, new CaptureGestureListener());
    _ScaleGestureDetector = new ScaleGestureDetector(this, new ScaleListener());

    _TorchButton = findViewById(getResources().getIdentifier("torch_button", "id", this.getPackageName()));

    _TorchButton.setOnClickListener(new View.OnClickListener() {
      @Override
      public void onClick(View v) {

        LiveData<Integer> flashState = camera.getCameraInfo().getTorchState();
        if (flashState.getValue() != null) {
          boolean state = flashState.getValue() == 1;
          _TorchButton.setBackgroundResource(getResources().getIdentifier(!state ? "torch_active" : "torch_inactive",
              "drawable", CaptureActivity.this.getPackageName()));
          camera.getCameraControl().enableTorch(!state);
        }

      }
    });

  }

  // ----------------------------------------------------------------------------
  // | Helper classes
  // ----------------------------------------------------------------------------
  private class CaptureGestureListener extends GestureDetector.SimpleOnGestureListener {
    @Override
    public boolean onSingleTapConfirmed(MotionEvent e) {
      if (_HighlightMode && selectHitAt(e.getRawX(), e.getRawY())) {
        return true;
      }
      return super.onSingleTapConfirmed(e);
    }
  }

  private class ScaleListener implements ScaleGestureDetector.OnScaleGestureListener {
    @Override
    public boolean onScale(ScaleGestureDetector detector) {
      return false;
    }

    @Override
    public boolean onScaleBegin(ScaleGestureDetector detector) {
      return true;
    }

    @Override
    public void onScaleEnd(ScaleGestureDetector detector) {

      if (camera != null) {
        float scale = camera.getCameraInfo().getZoomState().getValue().getZoomRatio() * detector.getScaleFactor();
        camera.getCameraControl().setZoomRatio(scale);
      }
    }
  }

  private void requestCameraPermission() {

    final String[] permissions = new String[] { Manifest.permission.CAMERA };

    boolean shouldShowPermission = !ActivityCompat.shouldShowRequestPermissionRationale(this,
        Manifest.permission.CAMERA);

    if (shouldShowPermission) {
      ActivityCompat.requestPermissions(this, permissions, RC_HANDLE_CAMERA_PERM);
      return;
    }

    View.OnClickListener listener = new View.OnClickListener() {
      @Override
      public void onClick(View view) {
        ActivityCompat.requestPermissions(CaptureActivity.this, permissions, RC_HANDLE_CAMERA_PERM);
      }
    };

    findViewById(getResources().getIdentifier("topLayout", "id", getPackageName())).setOnClickListener(listener);
    Snackbar
        .make(surfaceView, getResources().getIdentifier("permission_camera_rationale", "string", getPackageName()),
            Snackbar.LENGTH_INDEFINITE)
        .setAction(getResources().getIdentifier("ok", "string", getPackageName()), listener).show();

  }

  @Override
  public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
    if (requestCode != RC_HANDLE_CAMERA_PERM) {
      super.onRequestPermissionsResult(requestCode, permissions, grantResults);
      return;
    }

    if (grantResults.length != 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
      startCamera();
      drawOverlay();
      return;
    }

    DialogInterface.OnClickListener listener = new DialogInterface.OnClickListener() {
      public void onClick(DialogInterface dialog, int id) {
        finish();
      }
    };

    AlertDialog.Builder builder = new AlertDialog.Builder(this);
    builder.setTitle("Camera permission required")
        .setMessage(getResources().getIdentifier("no_camera_permission", "string", getPackageName()))
        .setPositiveButton(getResources().getIdentifier("ok", "string", getPackageName()), listener).show();
  }

  @Override
  public void surfaceCreated(SurfaceHolder surfaceHolder) {

  }

  @Override
  public void surfaceChanged(SurfaceHolder surfaceHolder, int i, int i1, int i2) {
    drawOverlay();
  }

  @Override
  public void surfaceDestroyed(SurfaceHolder surfaceHolder) {

  }

  @Override
  public boolean onTouchEvent(MotionEvent e) {
    boolean b = _ScaleGestureDetector.onTouchEvent(e);
    boolean c = _GestureDetector.onTouchEvent(e);

    return b || c || super.onTouchEvent(e);
  }

  @Override
  protected void onPause() {
    super.onPause();

  }

  @Override
  protected void onResume() {
    super.onResume();

  }

  void startCamera() {
    mCameraView = findViewById(getResources().getIdentifier("previewView", "id", getPackageName()));
    mCameraView.setImplementationMode(PreviewView.ImplementationMode.COMPATIBLE);

    Boolean rotateCamera = getIntent().getBooleanExtra("RotateCamera", false);
    if (rotateCamera) {
      mCameraView.setScaleX(-1F);
      mCameraView.setScaleY(-1F);
    } else {
      mCameraView.setScaleX(1F);
      mCameraView.setScaleY(1F);
    }

    // The analysis crop and the highlight overlay assume the preview fills the view (center crop).
    mCameraView.setScaleType(PreviewView.ScaleType.FILL_CENTER);

    cameraProviderFuture = ProcessCameraProvider.getInstance(this);
    cameraProviderFuture.addListener(new Runnable() {
      @Override
      public void run() {
        try {
          ProcessCameraProvider cameraProvider = cameraProviderFuture.get();
          CaptureActivity.this.bindPreview(cameraProvider);

        } catch (ExecutionException | InterruptedException e) {
          // No errors need to be handled for this Future.
          // This should never be reached.
        }
      }
    }, ContextCompat.getMainExecutor(this));
  }

  /**
   * Binding to camera
   */
  private void bindPreview(ProcessCameraProvider cameraProvider) {

    int barcodeFormat;
    if (BarcodeFormats == 0 || BarcodeFormats == 1234) {
      barcodeFormat = (Barcode.FORMAT_CODE_39 | Barcode.FORMAT_DATA_MATRIX);
    } else {
      barcodeFormat = BarcodeFormats;
    }

    Preview preview = new Preview.Builder().setTargetAspectRatio(AspectRatio.RATIO_16_9).build();

    CameraSelector cameraSelector = new CameraSelector.Builder().requireLensFacing(CameraSelector.LENS_FACING_BACK)
        .build();

    preview.setSurfaceProvider(mCameraView.getSurfaceProvider());

    ImageAnalysis imageAnalysis = new ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).setTargetAspectRatio(AspectRatio.RATIO_16_9)
        .build();

    BarcodeScanner scanner = BarcodeScanning
        .getClient(new BarcodeScannerOptions.Builder().setBarcodeFormats(barcodeFormat).build());

    imageAnalysis.setAnalyzer(executor, new ImageAnalysis.Analyzer() {
      @SuppressLint("UnsafeOptInUsageError")
      @Override
      public void analyze(@NonNull ImageProxy image) {

        if (image.getImage() == null) {
          image.close();
          return;
        }

        // In capture button mode only analyze the frame after the user tapped the button.
        if (_CaptureButtonMode && !_HighlightMode && !_CaptureRequested) {
          image.close();
          return;
        }

        final Bitmap bmp = BitmapUtils.getBitmap(image);
        final float viewWidth = surfaceView.getWidth();
        final float viewHeight = surfaceView.getHeight();

        if (bmp == null || viewWidth == 0 || viewHeight == 0) {
          image.close();
          return;
        }

        // The preview fills the view (center crop). Map the on screen target area back to
        // image coordinates so exactly what is inside the target area gets scanned.
        final int imageWidth = bmp.getWidth();
        final int imageHeight = bmp.getHeight();
        final float scale = Math.max(viewWidth / imageWidth, viewHeight / imageHeight);
        final float dx = (viewWidth - imageWidth * scale) / 2f;
        final float dy = (viewHeight - imageHeight * scale) / 2f;

        RectF target = getTargetRect(viewWidth, viewHeight);
        final int left = clamp(Math.round((target.left - dx) / scale), 0, imageWidth - 1);
        final int top = clamp(Math.round((target.top - dy) / scale), 0, imageHeight - 1);
        final int right = clamp(Math.round((target.right - dx) / scale), left + 1, imageWidth);
        final int bottom = clamp(Math.round((target.bottom - dy) / scale), top + 1, imageHeight);

        Bitmap bitmap = Bitmap.createBitmap(bmp, left, top, right - left, bottom - top);

        // The bitmap is already upright, so no further rotation is needed when we draw boxes.
        int rotation = _HighlightMode ? 0 : image.getImageInfo().getRotationDegrees();

        scanner.process(InputImage.fromBitmap(bitmap, rotation))
            .addOnSuccessListener(new OnSuccessListener<List<Barcode>>() {
              @Override
              public void onSuccess(List<Barcode> barCodes) {

                if (_HighlightMode) {
                  updateHits(barCodes, left, top, scale, dx, dy, viewWidth, viewHeight);
                  return;
                }

                if (_CaptureButtonMode && barCodes.isEmpty()) {
                  _CaptureRequested = false;
                  showNoBarcodeFound();
                }

                if (barCodes.size() > 0) {
                  deliverBarcode(barCodes.get(0));
                }
              }
            }).addOnFailureListener(new OnFailureListener() {
              @Override
              public void onFailure(@NonNull Exception e) {

              }
            }).addOnCompleteListener(new OnCompleteListener<List<Barcode>>() {
              @Override
              public void onComplete(@NonNull Task<List<Barcode>> task) {
                image.close();
              }
            });
      }

    });

    camera = cameraProvider.bindToLifecycle((LifecycleOwner) this, cameraSelector, imageAnalysis, preview);
  }

  // ----------------------------------------------------------------------------
  // | Target area, highlight overlay and selection
  // ----------------------------------------------------------------------------
  private static int clamp(int value, int min, int max) {
    return Math.max(min, Math.min(max, value));
  }

  private void createPaints() {
    _Density = getResources().getDisplayMetrics().density;

    _TargetPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _TargetPaint.setStyle(Paint.Style.STROKE);
    _TargetPaint.setColor(Color.WHITE);
    _TargetPaint.setStrokeWidth(5);

    _HitPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _HitPaint.setStyle(Paint.Style.STROKE);
    _HitPaint.setColor(Color.parseColor("#FFC107"));
    _HitPaint.setStrokeWidth(3 * _Density);
    _HitPaint.setStrokeJoin(Paint.Join.ROUND);

    _SelectedPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _SelectedPaint.setStyle(Paint.Style.STROKE);
    _SelectedPaint.setColor(Color.parseColor("#00E676"));
    _SelectedPaint.setStrokeWidth(4 * _Density);
    _SelectedPaint.setStrokeJoin(Paint.Join.ROUND);

    _SelectedFillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _SelectedFillPaint.setStyle(Paint.Style.FILL);
    _SelectedFillPaint.setColor(Color.parseColor("#4000E676"));

    _LabelPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _LabelPaint.setColor(Color.WHITE);
    _LabelPaint.setTextSize(14 * _Density);

    _LabelBackgroundPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    _LabelBackgroundPaint.setStyle(Paint.Style.FILL);
    _LabelBackgroundPaint.setColor(Color.parseColor("#CC000000"));
  }

  /** The area (in view coordinates) in which barcodes are scanned. */
  private RectF getTargetRect(float viewWidth, float viewHeight) {
    float base = Math.min(viewWidth, viewHeight);
    float width = Math.min((float) (DetectorSize * base), viewWidth);
    float height = Math.min((float) ((DetectorHeight > 0 ? DetectorHeight : DetectorSize) * base), viewHeight);
    return new RectF(viewWidth / 2 - width / 2, viewHeight / 2 - height / 2, viewWidth / 2 + width / 2,
        viewHeight / 2 + height / 2);
  }

  private static String getBarcodeValue(Barcode barcode) {
    String value = barcode.getRawValue();
    if (value == null && barcode.getRawBytes() != null) {
      value = new String(barcode.getRawBytes(), StandardCharsets.US_ASCII);
    }
    return value == null ? "" : value;
  }

  private void showNoBarcodeFound() {
    Toast.makeText(CaptureActivity.this,
        getResources().getIdentifier("no_barcode_found", "string", getPackageName()), Toast.LENGTH_SHORT).show();
  }

  private void deliverBarcode(Barcode barcode) {
    if (_Finished) {
      return;
    }
    _Finished = true;

    Intent data = new Intent();

    // rawValue returns null if string is not UTF-8 encoded.
    // If that's the case, we will decode it as ASCII,
    // because it's the most common encoding for barcodes.
    // e.g. https://www.barcodefaq.com/1d/code-128/
    data.putExtra(BarcodeFormat, barcode.getFormat());
    data.putExtra(BarcodeType, barcode.getValueType());
    data.putExtra(BarcodeValue, getBarcodeValue(barcode));
    setResult(CommonStatusCodes.SUCCESS, data);
    finish();
  }

  /** Converts the detected barcodes to view coordinates and picks the one that would be scanned. */
  private void updateHits(List<Barcode> barcodes, int cropLeft, int cropTop, float scale, float dx, float dy,
      float viewWidth, float viewHeight) {
    _Hits.clear();

    for (Barcode barcode : barcodes) {
      Point[] corners = barcode.getCornerPoints();
      if (corners == null || corners.length == 0) {
        android.graphics.Rect box = barcode.getBoundingBox();
        if (box == null) {
          continue;
        }
        corners = new Point[] { new Point(box.left, box.top), new Point(box.right, box.top),
            new Point(box.right, box.bottom), new Point(box.left, box.bottom) };
      }

      Hit hit = new Hit();
      hit.barcode = barcode;
      hit.value = getBarcodeValue(barcode);
      hit.key = hit.value + "|" + barcode.getFormat();
      hit.points = new PointF[corners.length];
      hit.bounds = new RectF(Float.MAX_VALUE, Float.MAX_VALUE, -Float.MAX_VALUE, -Float.MAX_VALUE);

      for (int i = 0; i < corners.length; i++) {
        float x = (cropLeft + corners[i].x) * scale + dx;
        float y = (cropTop + corners[i].y) * scale + dy;
        if (_RotateCamera) {
          x = viewWidth - x;
          y = viewHeight - y;
        }
        hit.points[i] = new PointF(x, y);
        hit.bounds.left = Math.min(hit.bounds.left, x);
        hit.bounds.top = Math.min(hit.bounds.top, y);
        hit.bounds.right = Math.max(hit.bounds.right, x);
        hit.bounds.bottom = Math.max(hit.bounds.bottom, y);
      }
      _Hits.add(hit);
    }

    // Keep the barcode the user selected as long as it is still visible,
    // otherwise preselect the one closest to the center of the target area.
    Hit selected = null;
    if (_UserSelectedKey != null) {
      for (Hit hit : _Hits) {
        if (hit.key.equals(_UserSelectedKey)) {
          selected = hit;
          break;
        }
      }
      if (selected == null) {
        _UserSelectedKey = null;
      }
    }

    if (selected == null) {
      float cx = viewWidth / 2;
      float cy = viewHeight / 2;
      float best = Float.MAX_VALUE;
      for (Hit hit : _Hits) {
        float distance = (float) Math.hypot(hit.bounds.centerX() - cx, hit.bounds.centerY() - cy);
        if (distance < best) {
          best = distance;
          selected = hit;
        }
      }
    }

    _Selected = selected;
    drawOverlay();
  }

  /** Lets the user select another highlighted barcode by tapping on it. */
  private boolean selectHitAt(float rawX, float rawY) {
    int[] location = new int[2];
    surfaceView.getLocationOnScreen(location);
    float x = rawX - location[0];
    float y = rawY - location[1];
    float slop = 24 * _Density;

    Hit best = null;
    float bestArea = Float.MAX_VALUE;
    for (Hit hit : _Hits) {
      RectF touchArea = new RectF(hit.bounds);
      touchArea.inset(-slop, -slop);
      if (touchArea.contains(x, y)) {
        float area = hit.bounds.width() * hit.bounds.height();
        if (area < bestArea) {
          bestArea = area;
          best = hit;
        }
      }
    }

    if (best == null) {
      return false;
    }

    _UserSelectedKey = best.key;
    _Selected = best;
    drawOverlay();
    return true;
  }

  /**
   * For drawing the target area and, in highlight mode, the detected barcodes
   */
  private void drawOverlay() {
    if (holder == null || !holder.getSurface().isValid()) {
      return;
    }

    Canvas canvas = holder.lockCanvas();
    if (canvas == null) {
      return;
    }

    try {
      canvas.drawColor(0, PorterDuff.Mode.CLEAR);

      float viewWidth = surfaceView.getWidth();
      float viewHeight = surfaceView.getHeight();
      RectF target = getTargetRect(viewWidth, viewHeight);

      // Changing the value of the radius will change the roundness of the box.
      float radius = Math.min(100f, Math.min(target.width(), target.height()) / 4f);
      if (DetectorSize <= 0.3 && DetectorHeight == 0) {
        canvas.drawRect(target, _TargetPaint);
      } else {
        canvas.drawRoundRect(target, radius, radius, _TargetPaint);
      }

      if (_HighlightMode) {
        for (Hit hit : _Hits) {
          if (hit != _Selected) {
            canvas.drawPath(createPath(hit), _HitPaint);
          }
        }
        if (_Selected != null) {
          Path path = createPath(_Selected);
          canvas.drawPath(path, _SelectedFillPaint);
          canvas.drawPath(path, _SelectedPaint);
          drawLabel(canvas, _Selected, viewWidth, viewHeight);
        }
      }
    } finally {
      holder.unlockCanvasAndPost(canvas);
    }
  }

  private Path createPath(Hit hit) {
    Path path = new Path();
    path.moveTo(hit.points[0].x, hit.points[0].y);
    for (int i = 1; i < hit.points.length; i++) {
      path.lineTo(hit.points[i].x, hit.points[i].y);
    }
    path.close();
    return path;
  }

  /** Shows the value of the selected barcode so the user can verify it is the right one. */
  private void drawLabel(Canvas canvas, Hit hit, float viewWidth, float viewHeight) {
    String text = hit.value;
    float maxWidth = viewWidth - 32 * _Density;
    float padding = 6 * _Density;

    while (text.length() > 1 && _LabelPaint.measureText(text) > maxWidth - 2 * padding) {
      text = text.substring(0, text.length() - 2) + "\u2026";
    }

    float textWidth = _LabelPaint.measureText(text);
    float textHeight = _LabelPaint.getTextSize();
    float boxWidth = textWidth + 2 * padding;
    float boxHeight = textHeight + 2 * padding;

    float left = clampFloat(hit.bounds.centerX() - boxWidth / 2, 16 * _Density, viewWidth - boxWidth - 16 * _Density);
    float top = hit.bounds.top - boxHeight - 6 * _Density;
    if (top < 0) {
      top = hit.bounds.bottom + 6 * _Density;
    }

    canvas.drawRoundRect(new RectF(left, top, left + boxWidth, top + boxHeight), padding, padding,
        _LabelBackgroundPaint);
    canvas.drawText(text, left + padding, top + padding + textHeight * 0.8f, _LabelPaint);
  }

  private static float clampFloat(float value, float min, float max) {
    return Math.max(min, Math.min(max, value));
  }
}
