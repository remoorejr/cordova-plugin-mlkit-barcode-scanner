/*
 Copyright 2016-present Google Inc. All Rights Reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

@import AVFoundation;
@import MLKitBarcodeScanning;
@import MLKitVision;

#import "CameraViewController.h"

@interface CameraViewController ()<AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, weak) IBOutlet UIView *placeHolderView;
@property(nonatomic, weak) IBOutlet UIView *overlayView;
@property(nonatomic, strong) UIImageView *imageView;

@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoDataOutput;
@property(nonatomic, strong) dispatch_queue_t videoDataOutputQueue;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property(nonatomic, strong) MLKBarcodeScanner *barcodeDetector;
@property(nonatomic, strong) UIButton *torchButton;
@property(atomic, assign) BOOL captureRequested;
@property(atomic, assign) BOOL processingFrame;
@property(atomic, assign) BOOL finished;
@property(nonatomic, strong) CIContext *ciContext;

// Target area (in view coordinates) in which barcodes are scanned.
@property(nonatomic, assign) CGRect targetRect;
@property(nonatomic, assign) CGSize viewSize;

// Highlight mode: barcodes detected inside the target area and the one that would be returned.
@property(nonatomic, strong) CALayer *highlightLayer;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) NSArray<NSDictionary *> *hits;
@property(nonatomic, strong) NSDictionary *selectedHit;
@property(nonatomic, copy) NSString *userSelectedKey;

@end

@implementation CameraViewController
@synthesize delegate;

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}

- (BOOL) shouldAutorotate
{
    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue",
                                                      DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Set up camera.
    self.session = [[AVCaptureSession alloc] init];
    self.session.sessionPreset = AVCaptureSessionPresetHigh;

    _videoDataOutputQueue = dispatch_queue_create("VideoDataOutputQueue",
                                                  DISPATCH_QUEUE_SERIAL);

    [self updateCameraSelection];

    // Set up video processing pipeline.
    [self setUpVideoProcessing];

    // Set up camera preview.
    [self setUpCameraPreview];

    //Parse Cordova settings.
    NSNumber *formats = 0;
    //If barcodeFormats == 0 then process as a VIN with VIN verifications.
    if([_barcodeFormats  isEqual: @0]) {
        NSLog(@"Running VIN style");
        formats = @(MLKBarcodeFormatCode39|MLKBarcodeFormatDataMatrix);
    } else if([_barcodeFormats  isEqual: @1234]) {
        // @todo: investigating what should be done here
    } else {
        formats = _barcodeFormats;
    }
    NSLog(@"_barcodeFormats %@, %@", _barcodeFormats, formats);

    // Initialize barcode detector.
    MLKBarcodeScannerOptions *options = [[MLKBarcodeScannerOptions alloc] initWithFormats: [formats intValue]];
    self.barcodeDetector = [MLKBarcodeScanner barcodeScannerWithOptions:options];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    self.previewLayer.frame = self.view.layer.bounds;
    self.previewLayer.position = CGPointMake(CGRectGetMidX(self.previewLayer.frame),
                                             CGRectGetMidY(self.previewLayer.frame));
}

- (void)dealloc {
    [self cleanupCaptureSession];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (authStatus == AVAuthorizationStatusDenied) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Camera permission required" message:@"Access to the camera has been prohibited, please enable it in the settings to continue." preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *primaryAction = [UIAlertAction actionWithTitle:@"Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
            [self.delegate closeScanner];
        }];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [self.delegate closeScanner];
        }];
        [alert addAction:cancelAction];
        [alert addAction:primaryAction];
        alert.preferredAction = primaryAction;
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        //Force portrait orientation.
        [[UIDevice currentDevice] setValue:
         [NSNumber numberWithInteger: UIInterfaceOrientationPortrait]
                                    forKey:@"orientation"];
        
        [self.session startRunning];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.session stopRunning];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    if (self.finished || self.processingFrame) {
        return;
    }

    // In capture button mode only analyze the frame after the user tapped the button.
    // (Highlight mode analyzes continuously and returns the selected barcode on tap.)
    if (self.captureButton && !self.highlightBarcode && !self.captureRequested) {
        return;
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (imageBuffer == NULL) {
        return;
    }
    CGFloat imageWidth = CVPixelBufferGetWidth(imageBuffer);
    CGFloat imageHeight = CVPixelBufferGetHeight(imageBuffer);
    CGSize viewSize = self.viewSize;
    CGRect targetRect = self.targetRect;
    if (imageWidth == 0 || imageHeight == 0 || viewSize.width == 0 || viewSize.height == 0) {
        return;
    }

    // The preview fills the view (aspect fill). Map the on screen target area back to
    // image coordinates so exactly what is inside the target area gets scanned.
    CGFloat scale = MAX(viewSize.width / imageWidth, viewSize.height / imageHeight);
    CGFloat dx = (viewSize.width - imageWidth * scale) / 2.0;
    CGFloat dy = (viewSize.height - imageHeight * scale) / 2.0;
    CGRect cropRect = CGRectMake((targetRect.origin.x - dx) / scale,
                                 (targetRect.origin.y - dy) / scale,
                                 targetRect.size.width / scale,
                                 targetRect.size.height / scale);
    cropRect = CGRectIntersection(CGRectIntegral(cropRect), CGRectMake(0, 0, imageWidth, imageHeight));
    if (CGRectIsEmpty(cropRect) || CGRectIsNull(cropRect)) {
        return;
    }

    if (self.ciContext == nil) {
        self.ciContext = [CIContext contextWithOptions:nil];
    }
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CGImageRef videoImage = [self.ciContext createCGImage:ciImage
                                                 fromRect:CGRectMake(0, 0, imageWidth, imageHeight)];
    if (videoImage == NULL) {
        return;
    }
    CGImageRef croppedImage = CGImageCreateWithImageInRect(videoImage, cropRect);
    CGImageRelease(videoImage);
    if (croppedImage == NULL) {
        return;
    }

    UIImage *image = [UIImage imageWithCGImage:croppedImage];
    CGImageRelease(croppedImage);

    MLKVisionImage *visionImage = [[MLKVisionImage alloc] initWithImage:image];
    visionImage.orientation = UIImageOrientationUp;

    self.processingFrame = YES;

    //Send the image through the barcode reader.
    [self.barcodeDetector processImage:visionImage completion:^(NSArray<MLKBarcode *> *barcodes,
                                                          NSError *error) {
        self.processingFrame = NO;

        if (error != nil || self.finished) {
            return;
        }

        if (self.highlightBarcode) {
            NSMutableArray *hits = [NSMutableArray array];
            for (MLKBarcode *barcode in barcodes) {
                NSArray<NSValue *> *corners = barcode.cornerPoints;
                if (corners.count == 0) {
                    CGRect f = barcode.frame;
                    corners = @[[NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(f), CGRectGetMinY(f))],
                                [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(f), CGRectGetMinY(f))],
                                [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(f), CGRectGetMaxY(f))],
                                [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(f), CGRectGetMaxY(f))]];
                }

                NSMutableArray<NSValue *> *points = [NSMutableArray array];
                CGRect bounds = CGRectNull;
                for (NSValue *corner in corners) {
                    CGPoint c = corner.CGPointValue;
                    CGPoint p = CGPointMake((cropRect.origin.x + c.x) * scale + dx,
                                            (cropRect.origin.y + c.y) * scale + dy);
                    [points addObject:[NSValue valueWithCGPoint:p]];
                    bounds = CGRectUnion(bounds, CGRectMake(p.x, p.y, 0, 0));
                }

                NSString *value = [self valueForBarcode:barcode];
                [hits addObject:@{@"barcode": barcode,
                                  @"value": value,
                                  @"key": [NSString stringWithFormat:@"%@|%ld", value, (long)barcode.format],
                                  @"points": points,
                                  @"rect": [NSValue valueWithCGRect:bounds]}];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateHits:hits];
            });
        } else if (self.captureButton && barcodes.count == 0) {
            self.captureRequested = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showNoBarcodeMessage];
            });
        } else if (barcodes.count > 0) {
            MLKBarcode *barcode = barcodes.firstObject;
            NSLog(@"Barcode value: %@", barcode.rawValue);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishWithBarcode:barcode];
            });
        }
    }];
}

#pragma mark - Camera setup

- (void)cleanupVideoProcessing {
    if (self.videoDataOutput) {
        [self.session removeOutput:self.videoDataOutput];
    }
    self.videoDataOutput = nil;
}

- (void)cleanupCaptureSession {
    [self.session stopRunning];
    [self cleanupVideoProcessing];
    self.session = nil;
    [self.previewLayer removeFromSuperlayer];
}

- (void)setUpVideoProcessing {
    self.videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    NSDictionary *rgbOutputSettings = @{
        (__bridge NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
    };
    [self.videoDataOutput setVideoSettings:rgbOutputSettings];

    if (![self.session canAddOutput:self.videoDataOutput]) {
        [self cleanupVideoProcessing];
        NSLog(@"Failed to setup video output");
        return;
    }
    [self.videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
    [self.videoDataOutput setSampleBufferDelegate:self queue:self.videoDataOutputQueue];
    [self.session addOutput:self.videoDataOutput];

    // Deliver upright (portrait) frames so image coordinates map straight onto the preview.
    AVCaptureConnection *connection = [self.videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection != nil) {
        if (@available(iOS 17.0, *)) {
            if ([connection isVideoRotationAngleSupported:90]) {
                connection.videoRotationAngle = 90;
            }
        } else if (connection.isVideoOrientationSupported) {
            connection.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
    }
}

- (void)setUpCameraPreview {
    self.previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:self.session];
    [self.previewLayer setBackgroundColor:[UIColor blackColor].CGColor];
    [self.previewLayer setVideoGravity:AVLayerVideoGravityResizeAspectFill];

    self.previewLayer.frame = self.view.superview.bounds;
    [self.view.layer addSublayer:self.previewLayer];

    CGRect screenRect = [[UIScreen mainScreen] bounds];
    CGFloat screenWidth = screenRect.size.width;
    CGFloat screenHeight = screenRect.size.height;

    // The target area is a rectangle: detectorSize is its width and detectorHeight its height,
    // both relative to the smaller screen dimension. Without detectorHeight it is a square.
    CGFloat baseSize = MIN(screenWidth, screenHeight);
    CGFloat frameWidth = MIN(baseSize * _detectorSize, screenWidth);
    CGFloat frameHeight = MIN(baseSize * (_detectorHeight > 0 ? _detectorHeight : _detectorSize), screenHeight);
    self.viewSize = CGSizeMake(screenWidth, screenHeight);
    self.targetRect = CGRectMake(screenWidth/2 - frameWidth/2, screenHeight/2 - frameHeight/2, frameWidth, frameHeight);

    UILabel* _label1 = [[UILabel alloc] init];
    _label1.frame = CGRectMake(screenWidth/2 - frameWidth/2, screenHeight/2 - frameHeight/2, frameWidth, frameHeight);
    _label1.layer.masksToBounds = NO;
    _label1.layer.cornerRadius = MIN(30.0, frameHeight / 4.0);
    _label1.userInteractionEnabled = YES;
    _label1.layer.borderColor = [UIColor whiteColor].CGColor;
    _label1.layer.borderWidth = 3.0;
    UITapGestureRecognizer* tapScanner = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(focusAtPoint:)];
    [_label1 addGestureRecognizer:tapScanner];

    CGFloat buttonSize = 45.0;

    UIButton *_cancelButton = [[UIButton alloc] init];
    [_cancelButton addTarget:self
                      action:@selector(closeView:)
            forControlEvents:UIControlEventTouchUpInside];

    NSString * cancelBase64String = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAQAAABpN6lAAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAAmJLR0QAAKqNIzIAAAAJcEhZcwAADdcAAA3XAUIom3gAAAAHdElNRQfhCxMVEyaNvw4TAAADNElEQVR42u2dv1LqQBSHv1DwBjY0FjyAA7wCtna2ttrwLr6GY4PWKfQBJGNtb2PDMFQ2ewvmDheBC0l295zjYVO6Cb/vC4b82c0p+Lf1GDNkwAVfzKh4oyRguxWMGTFgyBnvVMwo+dzd8Y4F4cfyQl+aoFXr87LFtOCW4mfHc8qtjqtlyWS7u4lWMGG5h6rkfBN/vqfjapnSlaap3bpM/8s0Xyso9u799fJkTEGXp4NM5d9v9t3BrtYUHIMfCNwC9HYc+mwrOBY/sKAHN0d2tqLgePxA4Abua3TXr6AefuAeXmutoFtBXfzAKwd+AC0pqI8fmMNH7ZV0KmiCH/iAhwar6VPQDD/w0KFq9IFXPCpS0OWRq0ZrVnDZyJymb0HTvR8IXEKx43rJkoI2+C+rk+H+3msm/Qra4C/Xl/qTxhuRVdAGPzBZb6g4cOmoU0E7/OnmXY52G5NQED2xLQVJ0tpRkCypDQVJU+pXkDyhbgVZ0ulVkC2ZTgVZU+lTkD2RLgUiafQoEEuiQ4FoCnkF4glkA4jjy4ZQgS8XRA2+TBhV+PkDqcPPG0olfr5gavHzhFONnz6gevy0IU3gpwtqBj9NWFP48QObw48b2iR+vOBm8eOEN40fQ4Fx/PYKzONLKVCEL6FAGX5uBQrxcypQip9LgWL8HAqU46dWYAA/pQIj+KkUGMJPocAYfmwFBvFjKjCKH0uBYfwYCpLjd6QN/e7m/F/A+UHQ+c+g8xMh56fCzi+GnF8OO78h4vyWmPObos5vizt/MOL80Zjzh6POH487HyDhfIiM80FSzofJOR8o6XyorPPB0s6HyzufMOF8yozzSVPOp805nzjpfOqs88nTzqfPiwfw/v4I0RQ68MWS6MEXSaMLP3siffhZU+nEz5ZML36WdLrxkyfUj580pQ38ZEnt4CdJaws/emL3r9Z2/nJ156/Xd19gwXmJjQ6jhh/7zDXf0uwAfHPNc8N1R+7L7JwKLZ1KbTkvtla30pSeQ9+uVv9wWJ0KLp5Kbrovunoqu4v7wssrBa5Lb6+6uyy+vrlve4wZMuCCL2ZUvFESpBlatoIxIwYMOeOdihkln+s//wFFdoCM42fEswAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAxNy0xMS0xOVQyMToxOTozOCswMTowMPNH2M8AAAAldEVYdGRhdGU6bW9kaWZ5ADIwMTctMTEtMTlUMjE6MTk6MzgrMDE6MDCCGmBzAAAAGXRFWHRTb2Z0d2FyZQB3d3cuaW5rc2NhcGUub3Jnm+48GgAAAABJRU5ErkJggg==";

    NSURL *cancelImageUrl = [NSURL URLWithString:cancelBase64String];
    NSData *cancelImageData = [NSData dataWithContentsOfURL:cancelImageUrl];
    UIImage *cancelIcon = [UIImage imageWithData:cancelImageData];
    [_cancelButton setImage:cancelIcon
                   forState:UIControlStateNormal];

    CGFloat screenOffset = MAX(16.0, (screenWidth/2 - frameWidth/2)/2 - buttonSize/2);
    NSLog(@"screenOffset %f", screenOffset);

    _cancelButton.frame = CGRectMake(screenOffset, screenHeight-screenOffset-buttonSize, buttonSize, buttonSize);
    _cancelButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    _cancelButton.transform=CGAffineTransformMakeRotation(M_PI / 2);
    _cancelButton.layer.cornerRadius = buttonSize/2;
    _cancelButton.contentEdgeInsets = UIEdgeInsetsMake(15, 15, 15, 15);

    [self.view addSubview:_cancelButton];




    self.torchButton = [[UIButton alloc] init];
    [self.torchButton addTarget:self
                         action:@selector(toggleFlashlight:)
               forControlEvents:UIControlEventTouchUpInside];

    NSString * torchBase64String = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAQAAABpN6lAAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAAAmJLR0QAAKqNIzIAAAAJcEhZcwAADdcAAA3XAUIom3gAAAAHdElNRQfhCxMVAzOqoPipAAADM0lEQVR42u2dv2sTcRyG38RWzGYHhxYHp+B+Lk7iIlhFXZvdPeAouOuS1X/AVCiiCBU6OjgIOffG+gvEgCIqlsQi9JxEbC/XJt8fz136eTJecve+T+6Su8t9czX5oqmWEiVa9DbHfAZKlaqrfuDlTERNbQ2VRXwM1VaNrv2v/nrU8n8f62VR0EbqZ8rUpqtLUjPyyv//htB0jV93FrCiBia/oRYv4BxWX5IS1xm4f4x8Cv7FV8RAS7SADKzvoYH7JlBxTAAdgMYE0AFoTAAdwDAMwzAMo7q8ws4IZsr0wjW++57gFqrfeenuAt6YAJLXvADbBFABJVgDPmobrP+DF5BpAxPwyH0WPk6IPKmyAB8/MJ/UZ80D9T/ojPtMfKwB3/UcqO/l/fd1TvAxIuAhstRclrQT/ShgzU/0Y17m8lMLOh9V+UjX3L8CfbKgr1Hf/zt04f3EvFLorU7QdfdzXFuR6v/SRbpsPjci1b9MFx3P7eD1d3SFLlnM3cD1r9IFD+Z+wJW/AvWluh4EqT/UJbraYZnTmvf627pA12IV3KQrTa7gqcf6z+g603BKXzzV/+Z6NSjFiicB9+gi07PhRcBZusb0XPdQ3/nXP5J5D58Dt8JGDHuZ3G8Pp60C//AS+jrBl85zeBc24FxgAe/HTulrVT2lkhIlao0d/RNYQGhO527Xu+rsGWnUUEe7uc+tOPXc+su5z13OVVB59lfqjH1u5ygI2CwYZtfQZmwB8a8WX9Vo7LSRurHjxBfQK5yaRs8TnL2rdPEow8XZ3wRKRnwBicPUmRBQPNY4uoDwlPxrML6AI78jZLvC5ToYCv83JOMqHPZwOHBCTkBJEtqOEB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgTQAWhMAB2AxgQEX8IAfHUpBLgNhg0+lDa8gJ7Tq2dgLLHLbXk93Fa3DEz/d6ttOrofpr01d2lure1DwaQ3Z492c/V4jptqKVFy4F2KB0qVqqt+nFh/ADjJgLiaxweIAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDE3LTExLTE5VDIxOjAzOjUxKzAxOjAwdhzbkgAAACV0RVh0ZGF0ZTptb2RpZnkAMjAxNy0xMS0xOVQyMTowMzo1MSswMTowMAdBYy4AAAAZdEVYdFNvZnR3YXJlAHd3dy5pbmtzY2FwZS5vcmeb7jwaAAAAAElFTkSuQmCCconv";

    NSURL *torchImageUrl = [NSURL URLWithString:torchBase64String];
    NSData *torchImageData = [NSData dataWithContentsOfURL:torchImageUrl];
    UIImage *torchIcon = [UIImage imageWithData:torchImageData];
    [self.torchButton setImage:torchIcon
                      forState:UIControlStateNormal];

    self.torchButton.frame = CGRectMake(screenWidth-screenOffset-buttonSize, screenHeight-screenOffset-buttonSize, buttonSize, buttonSize);
    self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.4];
    self.torchButton.transform=CGAffineTransformMakeRotation(M_PI / 2);
    self.torchButton.layer.cornerRadius = buttonSize/2;
    self.torchButton.contentEdgeInsets = UIEdgeInsetsMake(10, 10, 10, 10);

    [self.view addSubview:self.torchButton];

    // Highlight mode needs a button to confirm the selected barcode.
    if (self.captureButton || self.highlightBarcode) {
        CGFloat captureSize = 72.0;
        UIButton *captureButton = [[UIButton alloc] initWithFrame:CGRectMake(screenWidth/2 - captureSize/2,
                                                                            screenHeight-screenOffset-buttonSize/2-captureSize/2,
                                                                            captureSize, captureSize)];
        captureButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        captureButton.layer.cornerRadius = captureSize/2;
        captureButton.layer.borderColor = [UIColor whiteColor].CGColor;
        captureButton.layer.borderWidth = 4.0;
        captureButton.accessibilityLabel = NSLocalizedString(@"Capture", @"Capture button label");
        UIView *inner = [[UIView alloc] initWithFrame:CGRectInset(captureButton.bounds, 10, 10)];
        inner.backgroundColor = [UIColor whiteColor];
        inner.layer.cornerRadius = inner.bounds.size.width/2;
        inner.userInteractionEnabled = NO;
        [captureButton addSubview:inner];
        [captureButton addTarget:self
                          action:@selector(captureTapped:)
                forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:captureButton];
    }

    [self.view addSubview:_label1];

    self.imageView = [[UIImageView alloc] initWithImage:nil];

    UIView *catView = [[UIView alloc] initWithFrame:CGRectMake(0,0,frameWidth,frameHeight)];
    self.imageView.frame = catView.bounds;

    // add the imageview to the superview
    [catView addSubview:self.imageView];

    //add the view to the main view

    [self.view addSubview:catView];

    if (self.highlightBarcode) {
        self.highlightLayer = [CALayer layer];
        self.highlightLayer.frame = CGRectMake(0, 0, screenWidth, screenHeight);
        [self.view.layer addSublayer:self.highlightLayer];

        self.valueLabel = [[UILabel alloc] init];
        self.valueLabel.textColor = [UIColor whiteColor];
        self.valueLabel.font = [UIFont systemFontOfSize:14];
        self.valueLabel.textAlignment = NSTextAlignmentCenter;
        self.valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        self.valueLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        self.valueLabel.layer.cornerRadius = 6;
        self.valueLabel.layer.masksToBounds = YES;
        self.valueLabel.userInteractionEnabled = NO;
        self.valueLabel.hidden = YES;
        [self.view addSubview:self.valueLabel];
    }

}

#pragma mark - Helper Functions

- (void)captureTapped:(id)sender {
    if (self.highlightBarcode) {
        if (self.selectedHit != nil) {
            [self finishWithBarcode:self.selectedHit[@"barcode"]];
        } else {
            [self showNoBarcodeMessage];
        }
    } else {
        self.captureRequested = YES;
    }
}

- (NSString *)valueForBarcode:(MLKBarcode *)barcode {
    NSString *value = barcode.rawValue;

    // rawValue returns null if string is not UTF-8 encoded.
    // If that's the case, we will decode it as ASCII,
    // because it's the most common encoding for barcodes.
    if (value == nil && barcode.rawData != nil) {
        value = [[NSString alloc] initWithData:barcode.rawData encoding:NSASCIIStringEncoding];
    }
    return value ?: @"";
}

- (void)finishWithBarcode:(MLKBarcode *)barcode {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self cleanupCaptureSession];
    [self->_session stopRunning];
    [self->delegate sendResult:barcode];
}

// Keeps the barcode the user selected as long as it is still visible,
// otherwise preselects the one closest to the center of the target area.
- (void)updateHits:(NSArray<NSDictionary *> *)hits {
    self.hits = hits;

    NSDictionary *selected = nil;
    if (self.userSelectedKey != nil) {
        for (NSDictionary *hit in hits) {
            if ([hit[@"key"] isEqualToString:self.userSelectedKey]) {
                selected = hit;
                break;
            }
        }
        if (selected == nil) {
            self.userSelectedKey = nil;
        }
    }

    if (selected == nil) {
        CGPoint center = CGPointMake(CGRectGetMidX(self.targetRect), CGRectGetMidY(self.targetRect));
        CGFloat best = CGFLOAT_MAX;
        for (NSDictionary *hit in hits) {
            CGRect r = [hit[@"rect"] CGRectValue];
            CGFloat distance = hypot(CGRectGetMidX(r) - center.x, CGRectGetMidY(r) - center.y);
            if (distance < best) {
                best = distance;
                selected = hit;
            }
        }
    }

    self.selectedHit = selected;
    [self renderHits];
}

// Lets the user select another highlighted barcode by tapping on it.
- (BOOL)selectHitAtPoint:(CGPoint)point {
    NSDictionary *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (NSDictionary *hit in self.hits) {
        CGRect r = CGRectInset([hit[@"rect"] CGRectValue], -24, -24);
        if (CGRectContainsPoint(r, point)) {
            CGRect own = [hit[@"rect"] CGRectValue];
            CGFloat area = own.size.width * own.size.height;
            if (area < bestArea) {
                bestArea = area;
                best = hit;
            }
        }
    }
    if (best == nil) {
        return NO;
    }
    self.userSelectedKey = best[@"key"];
    self.selectedHit = best;
    [self renderHits];
    return YES;
}

- (void)renderHits {
    for (CALayer *layer in [self.highlightLayer.sublayers copy]) {
        [layer removeFromSuperlayer];
    }

    UIColor *selectedColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.46 alpha:1.0];
    UIColor *otherColor = [UIColor colorWithRed:1.0 green:0.76 blue:0.03 alpha:1.0];

    for (NSDictionary *hit in self.hits) {
        BOOL isSelected = (hit == self.selectedHit);
        UIBezierPath *path = [UIBezierPath bezierPath];
        NSArray<NSValue *> *points = hit[@"points"];
        for (NSUInteger i = 0; i < points.count; i++) {
            CGPoint p = points[i].CGPointValue;
            if (i == 0) {
                [path moveToPoint:p];
            } else {
                [path addLineToPoint:p];
            }
        }
        [path closePath];

        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.path = path.CGPath;
        shape.lineWidth = isSelected ? 4.0 : 3.0;
        shape.lineJoin = kCALineJoinRound;
        shape.strokeColor = (isSelected ? selectedColor : otherColor).CGColor;
        shape.fillColor = isSelected ? [selectedColor colorWithAlphaComponent:0.25].CGColor : [UIColor clearColor].CGColor;
        [self.highlightLayer addSublayer:shape];
    }

    // Show the value of the selected barcode so the user can verify it is the right one.
    if (self.selectedHit == nil) {
        self.valueLabel.hidden = YES;
        return;
    }
    CGRect r = [self.selectedHit[@"rect"] CGRectValue];
    self.valueLabel.text = [NSString stringWithFormat:@" %@ ", self.selectedHit[@"value"]];
    CGFloat maxWidth = self.viewSize.width - 32;
    CGSize size = [self.valueLabel sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(size.width, maxWidth);
    CGFloat height = size.height + 8;
    CGFloat x = MAX(16, MIN(CGRectGetMidX(r) - width / 2, self.viewSize.width - width - 16));
    CGFloat y = CGRectGetMinY(r) - height - 6;
    if (y < 0) {
        y = CGRectGetMaxY(r) + 6;
    }
    self.valueLabel.frame = CGRectMake(x, y, width, height);
    self.valueLabel.hidden = NO;
}

- (void)showNoBarcodeMessage {
    UILabel *label = [[UILabel alloc] init];
    label.text = NSLocalizedString(@"No barcode found. Please try again.", @"Shown when capture finds no barcode.");
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    label.layer.cornerRadius = 8;
    label.layer.masksToBounds = YES;
    CGSize size = [label sizeThatFits:CGSizeMake(self.view.bounds.size.width - 80, CGFLOAT_MAX)];
    label.frame = CGRectMake(0, 0, size.width + 24, size.height + 16);
    label.center = CGPointMake(self.view.bounds.size.width/2, self.view.bounds.size.height - 150);
    [self.view addSubview:label];
    [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{
        label.alpha = 0;
    } completion:^(BOOL finished) {
        [label removeFromSuperview];
    }];
}

- (void)focusAtPoint:(id) sender {
    NSLog(@"captured touch");
    CGPoint touchPoint = [(UITapGestureRecognizer*)sender locationInView:self.view];
    if (self.highlightBarcode) {
        [self selectHitAtPoint:touchPoint];
    }
    double focus_x = touchPoint.x/self.previewLayer.frame.size.width;
    double focus_y = (touchPoint.y+66)/self.previewLayer.frame.size.height;

    NSError *error;
    NSArray *devices = [AVCaptureDevice devices];
    for (AVCaptureDevice *device in devices){
        NSLog(@"Device name: %@", [device localizedName]);
        if ([device hasMediaType:AVMediaTypeVideo]) {
            if ([device position] == AVCaptureDevicePositionBack) {
                NSLog(@"Device position : back");
                CGPoint point = CGPointMake(focus_y, 1-focus_x);
                if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus] && [device lockForConfiguration:&error]){
                    [device setFocusPointOfInterest:point];

                    for (UIView *subView in self.view.subviews)
                    {
                        if (subView.tag == 99)
                        {
                            [subView removeFromSuperview];
                        }
                    }

                    CGRect rect = CGRectMake(touchPoint.x-30, touchPoint.y-30, 60, 60);
                    UIView *focusRect = [[UIView alloc] initWithFrame:rect];
                    focusRect.layer.borderColor = [UIColor colorWithRed:0.98 green:0.80 blue:0.18 alpha:.7].CGColor;
                    focusRect.layer.borderWidth = 1;
                    focusRect.tag = 99;
                    [self.view addSubview:focusRect];

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        [focusRect removeFromSuperview];
                    });

                    [device setFocusMode:AVCaptureFocusModeAutoFocus];
                    [device unlockForConfiguration];
                }
            }
        }
    }
}
static inline double radians (double degrees) {return degrees * M_PI/180;}
- (UIImage*) rotateImage:(UIImage*)src toOrientation:(UIImageOrientation) orientation
{
    UIGraphicsBeginImageContext(src.size);

    CGContextRef context = UIGraphicsGetCurrentContext();

    if (orientation == UIImageOrientationRight) {
        CGContextRotateCTM (context, radians(90));
    } else if (orientation == UIImageOrientationLeft) {
        CGContextRotateCTM (context, radians(-90));
    } else if (orientation == UIImageOrientationDown) {
        // NOTHING
    } else if (orientation == UIImageOrientationUp) {
        CGContextRotateCTM (context, radians(90));
    }

    [src drawAtPoint:CGPointMake(0, 0)];

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)croppIngimageByImageName:(UIImage *)imageToCrop toRect:(CGRect)rect
{
    //CGRect CropRect = CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height+15);

    CGImageRef imageRef = CGImageCreateWithImageInRect([imageToCrop CGImage], rect);
    UIImage *cropped = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);

    return cropped;
}

- (void) toggleFlashlight:(id)sender
{
    // check if flashlight available
    Class captureDeviceClass = NSClassFromString(@"AVCaptureDevice");
    if (captureDeviceClass != nil) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCapturePhotoSettings *photosettings = [AVCapturePhotoSettings photoSettings];
        if ([device hasTorch] && [device hasFlash]){

            [device lockForConfiguration:nil];
            if (device.torchMode == AVCaptureTorchModeOff)
            {
                self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:1];
                [device setTorchMode:AVCaptureTorchModeOn];
                photosettings.flashMode = AVCaptureFlashModeOn;
                //torchIsOn = YES;
            }
            else
            {
                self.torchButton.backgroundColor = [UIColor colorWithWhite:1 alpha:.4];
                [device setTorchMode:AVCaptureTorchModeOff];
                photosettings.flashMode = AVCaptureFlashModeOff;
                // torchIsOn = NO;
            }
            [device unlockForConfiguration];
        }
    } }

- (void)closeView:(id)sender{
    [ self cleanupCaptureSession];
    [_session stopRunning];
    [delegate closeScanner];
}


- (void)updateCameraSelection {
    [self.session beginConfiguration];

    // Remove old inputs
    NSArray *oldInputs = [self.session inputs];
    for (AVCaptureInput *oldInput in oldInputs) {
        [self.session removeInput:oldInput];
    }

    AVCaptureDevicePosition desiredPosition = AVCaptureDevicePositionBack;
    AVCaptureDeviceInput *input = [self captureDeviceInputForPosition:desiredPosition];
    if (!input) {
        // Failed, restore old inputs
        for (AVCaptureInput *oldInput in oldInputs) {
            [self.session addInput:oldInput];
        }
    } else {
        // Succeeded, set input and update connection states
        [self.session addInput:input];
    }
    [self.session commitConfiguration];
}

- (AVCaptureDeviceInput *)captureDeviceInputForPosition:(AVCaptureDevicePosition)desiredPosition {
    for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (device.position == desiredPosition) {
            NSError *error = nil;
            AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                                                error:&error];
            if (error) {
                NSLog(@"Could not initialize for AVMediaTypeVideo for device %@", device);
            } else if ([self.session canAddInput:input]) {
                return input;
            }
        }
    }
    return nil;
}



@end
