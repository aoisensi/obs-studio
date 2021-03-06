#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <arpa/inet.h>

#include <obs.h>
#include <media-io/video-io.h>

#import "AVCaptureInputPort+PreMavericksCompat.h"

#define MILLI_TIMESCALE 1000
#define MICRO_TIMESCALE (MILLI_TIMESCALE * 1000)
#define NANO_TIMESCALE  (MICRO_TIMESCALE * 1000)

#define AV_REV_FOURCC(x) \
	(x & 255), ((x >> 8) & 255), ((x >> 16) & 255), (x >> 24)

struct av_capture;

@interface OBSAVCaptureDelegate :
	NSObject<AVCaptureVideoDataOutputSampleBufferDelegate>
{
@public
	struct av_capture *capture;
}
- (void)captureOutput:(AVCaptureOutput *)out
        didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection;
- (void)captureOutput:(AVCaptureOutput *)captureOutput
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection;
@end

struct av_capture {
	AVCaptureSession         *session;
	AVCaptureDevice          *device;
	AVCaptureDeviceInput     *device_input;
	AVCaptureVideoDataOutput *out;
	
	OBSAVCaptureDelegate *delegate;
	dispatch_queue_t queue;
	bool has_clock;

	unsigned fourcc;
	enum video_format video_format;

	obs_source_t source;

	struct source_frame frame;
};

static inline void update_frame_size(struct source_frame *frame,
		uint32_t width, uint32_t height)
{
	if (width != frame->width) {
		blog(LOG_DEBUG, "Changed width from %d to %d",
				frame->width, width);
		frame->width = width;
		frame->linesize[0] = width * 2;
	}

	if (height != frame->height) {
		blog(LOG_DEBUG, "Changed height from %d to %d",
				frame->height, height);
		frame->height = height;
	}
}

@implementation OBSAVCaptureDelegate
- (void)captureOutput:(AVCaptureOutput *)out
        didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
	UNUSED_PARAMETER(out);
	UNUSED_PARAMETER(sampleBuffer);
	UNUSED_PARAMETER(connection);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
	UNUSED_PARAMETER(captureOutput);
	UNUSED_PARAMETER(connection);

	CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
	if (count < 1 || !capture)
		return;

	struct source_frame *frame = &capture->frame;

	CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);

	update_frame_size(frame, CVPixelBufferGetWidth(img),
			CVPixelBufferGetHeight(img));

	CMSampleTimingInfo info;
	CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &info);
	CMTime target_pts;
	if (capture->has_clock) {
		AVCaptureInputPort *port = capture->device_input.ports[0];
		target_pts = CMSyncConvertTime(info.presentationTimeStamp,
				port.clock, CMClockGetHostTimeClock());

	} else {
		target_pts = info.presentationTimeStamp;
	}

	CMTime target_pts_nano = CMTimeConvertScale(target_pts, NANO_TIMESCALE,
			kCMTimeRoundingMethod_Default);
	frame->timestamp = target_pts_nano.value;

	CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);

	frame->data[0] = CVPixelBufferGetBaseAddress(img);
	obs_source_output_video(capture->source, frame);

	CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}
@end

static const char *av_capture_getname(const char *locale)
{
	/* TODO: locale */
	UNUSED_PARAMETER(locale);
	return "Video Capture Device";
}

static void av_capture_destroy(void *data)
{
	struct av_capture *capture = data;
	if (!capture)
		return;

	[capture->session stopRunning];

	[capture->out release];
	[capture->device_input release];
	[capture->device release];

	if (capture->queue)
		dispatch_release(capture->queue);
	[capture->delegate release];
	[capture->session release];

	bfree(capture);
}

static NSString *get_string(obs_data_t data, char const *name)
{
	return @(obs_data_getstring(data, name));
}

static bool init_session(struct av_capture *capture)
{
	capture->session = [[AVCaptureSession alloc] init];
	if (!capture->session) {
		blog(LOG_ERROR, "Could not create AVCaptureSession");
		return false;
	}

	capture->delegate = [[OBSAVCaptureDelegate alloc] init];
	if (!capture->delegate) {
		blog(LOG_ERROR, "Could not create OBSAvCaptureDelegate");
		return false;
	}

	capture->delegate->capture = capture;

	capture->out = [[AVCaptureVideoDataOutput alloc] init];
	if (!capture->out) {
		blog(LOG_ERROR, "Could not create AVCaptureVideoDataOutput");
		return false;
	}

	capture->queue = dispatch_queue_create(NULL, NULL);
	if (!capture->queue) {
		blog(LOG_ERROR, "Could not create dispatch queue");
		return false;
	}

	[capture->session addOutput:capture->out];
	[capture->out
		setSampleBufferDelegate:capture->delegate
				  queue:capture->queue];

	return true;
}

static bool init_device_input(struct av_capture *capture, obs_data_t settings)
{
	NSString *uid = get_string(settings, "device");
	capture->device = [[AVCaptureDevice deviceWithUniqueID:uid] retain];
	if (!capture->device) {
		if (uid.length < 1)
			blog(LOG_ERROR, "No device selected");
		else
			blog(LOG_ERROR, "Could not initialize device " \
					"with unique ID '%s'",
					uid.UTF8String);
		return false;
	}

	blog(LOG_DEBUG, "Selected device '%s'",
			capture->device.localizedName.UTF8String);

	NSError *err = nil;
	capture->device_input = [[AVCaptureDeviceInput
		deviceInputWithDevice:capture->device error:&err] retain];
	if (!capture->device_input) {
		blog(LOG_ERROR, "Error while initializing av-capture: %s",
				err.localizedFailureReason.UTF8String);
		return false;
	}

	[capture->session addInput:capture->device_input];

	return true;
}

static uint32_t uint_from_dict(NSDictionary *dict, CFStringRef key)
{
	return ((NSNumber*)dict[(__bridge NSString*)key]).unsignedIntValue;
}

static bool init_format(struct av_capture *capture)
{
	AVCaptureDeviceFormat *format = capture->device.activeFormat;

	CMMediaType mtype = CMFormatDescriptionGetMediaType(
			format.formatDescription);
	// TODO: support other media types
	if (mtype != kCMMediaType_Video) {
		blog(LOG_ERROR, "CMMediaType '%c%c%c%c' is unsupported",
				AV_REV_FOURCC(mtype));
		return false;
	}

	capture->out.videoSettings = nil;
	capture->fourcc = htonl(uint_from_dict(capture->out.videoSettings,
			kCVPixelBufferPixelFormatTypeKey));
	
	capture->video_format = video_format_from_fourcc(capture->fourcc);
	if (capture->video_format == VIDEO_FORMAT_NONE) {
		blog(LOG_ERROR, "FourCC '%c%c%c%c' unsupported by libobs",
				AV_REV_FOURCC(capture->fourcc));
		return false;
	}

	blog(LOG_DEBUG, "Using FourCC '%c%c%c%c'",
			AV_REV_FOURCC(capture->fourcc));

	return true;
}

static bool init_frame(struct av_capture *capture)
{
	AVCaptureDeviceFormat *format = capture->device.activeFormat;

	CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(
			format.formatDescription);
	capture->frame.width = size.width;
	capture->frame.linesize[0] = size.width * 2;
	capture->frame.height = size.height;
	capture->frame.format = capture->video_format;
	capture->frame.full_range = false;

	NSDictionary *exts =
		(__bridge NSDictionary*)CMFormatDescriptionGetExtensions(
				format.formatDescription);

	capture->frame.linesize[0] = uint_from_dict(exts,
			(__bridge CFStringRef)@"CVBytesPerRow");

	NSString *matrix_key =
		(__bridge NSString*)kCVImageBufferYCbCrMatrixKey;
	enum video_colorspace colorspace =
		exts[matrix_key] == (id)kCVImageBufferYCbCrMatrix_ITU_R_709_2 ?
			VIDEO_CS_709 : VIDEO_CS_601;

	if (!video_format_get_parameters(colorspace, VIDEO_RANGE_PARTIAL,
			capture->frame.color_matrix,
			capture->frame.color_range_min,
			capture->frame.color_range_max)) {
		blog(LOG_ERROR, "Failed to get video format parameters for " \
				"video format %u", colorspace);
		return false;
	}

	return true;
}

static void av_capture_init(struct av_capture *capture, obs_data_t settings)
{
	if (!init_session(capture))
		return;

	if (!init_device_input(capture, settings))
		return;

	AVCaptureInputPort *port = capture->device_input.ports[0];
	capture->has_clock = [port respondsToSelector:@selector(clock)];

	if (obs_data_getbool(settings, "use_preset")) {
		NSString *preset = [NSString
			stringWithUTF8String:obs_data_getstring(settings,
								"preset")];
		blog(LOG_DEBUG, "Using preset %s", preset.UTF8String);
		capture->session.sessionPreset = preset;
	}

	if (!init_format(capture))
		return;

	if (!init_frame(capture))
		return;
	
	[capture->session startRunning];
}

static void *av_capture_create(obs_data_t settings, obs_source_t source)
{
	UNUSED_PARAMETER(source);

	struct av_capture *capture = bzalloc(sizeof(struct av_capture));
	capture->source = source;

	av_capture_init(capture, settings);

	return capture;
}

static NSArray *presets() {
	return @[
		//AVCaptureSessionPresetPhoto,
		//AVCaptureSessionPresetLow,
		//AVCaptureSessionPresetMedium,
		//AVCaptureSessionPresetHigh,
		AVCaptureSessionPreset320x240,
		AVCaptureSessionPreset352x288,
		AVCaptureSessionPreset640x480,
		AVCaptureSessionPreset960x540,
		AVCaptureSessionPreset1280x720,
		//AVCaptureSessionPresetiFrame960x540,
		//AVCaptureSessionPresetiFrame1280x720,
	];
}

static NSString *preset_names(NSString *preset)
{
	NSDictionary *preset_names = @{
		AVCaptureSessionPresetLow:@"Low",
		AVCaptureSessionPresetMedium:@"Medium",
		AVCaptureSessionPresetHigh:@"High",
		AVCaptureSessionPreset320x240:@"320x240",
		AVCaptureSessionPreset352x288:@"352x288",
		AVCaptureSessionPreset640x480:@"640x480",
		AVCaptureSessionPreset960x540:@"960x540",
		AVCaptureSessionPreset1280x720:@"1280x720",
	};
	return preset_names[preset];
}


static void av_capture_defaults(obs_data_t settings)
{
	AVCaptureDevice *dev = [AVCaptureDevice
		defaultDeviceWithMediaType:AVMediaTypeVideo];
	if (!dev)
		return;

	NSString *highest = nil;
	for (NSString *preset in presets()) {
		if (![dev supportsAVCaptureSessionPreset:preset])
			continue;
		highest = preset;
	}
	if (!highest)
		return;

	obs_data_set_default_string(settings, "device",
			dev.uniqueID.UTF8String);
	obs_data_set_default_bool(settings, "use_preset", true);

	obs_data_set_default_string(settings, "preset", highest.UTF8String);
}

static obs_properties_t av_capture_properties(char const *locale)
{
	obs_properties_t props = obs_properties_create(locale);

	/* TODO: locale */
	obs_property_t dev_list = obs_properties_add_list(props, "device",
			"Device", OBS_COMBO_TYPE_LIST,
			OBS_COMBO_FORMAT_STRING);
	for (AVCaptureDevice *dev in [AVCaptureDevice
			devicesWithMediaType:AVMediaTypeVideo]) {
		obs_property_list_add_string(dev_list,
				dev.localizedName.UTF8String,
				dev.uniqueID.UTF8String);
	}
	// TODO: implement device selection
	obs_property_set_enabled(dev_list, false);

	obs_property_t use_preset = obs_properties_add_bool(props,
			"use_preset", "Use preset");
	// TODO: implement manual configuration
	obs_property_set_enabled(use_preset, false);

	AVCaptureDevice *dev = [AVCaptureDevice
		defaultDeviceWithMediaType:AVMediaTypeVideo];

	obs_property_t preset_list = obs_properties_add_list(props, "preset",
			"Preset", OBS_COMBO_TYPE_LIST,
			OBS_COMBO_FORMAT_STRING);
	if (dev) {
		for (NSString *preset in presets()) {
			if (![dev supportsAVCaptureSessionPreset:preset])
				continue;

			obs_property_list_add_string(preset_list,
					preset_names(preset).UTF8String,
					preset.UTF8String);
		}
	}

	return props;
}

// TODO: implement device selection
static void av_capture_update(void *data, obs_data_t settings)
{
	struct av_capture *cap = data;
	if (!cap || !settings)
		return;

	NSString *uid = get_string(settings, "device");

	if ([cap->device.uniqueID isEqualToString:uid]) {
		cap->session.sessionPreset = get_string(settings, "preset");
	}
}

struct obs_source_info av_capture_info = {
	.id           = "av_capture_input",
	.type         = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_ASYNC_VIDEO,
	.getname      = av_capture_getname,
	.create       = av_capture_create,
	.destroy      = av_capture_destroy,
	.defaults     = av_capture_defaults,
	.properties   = av_capture_properties,
	.update       = av_capture_update,
};

