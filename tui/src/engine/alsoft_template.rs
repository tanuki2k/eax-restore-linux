//! The alsoft.ini an install writes, from OpenAL Soft's own reference
//! file's descriptions. Copied out of `src/install-flow.sh` by a script, so
//! the text is the script's word for word.

/// The main part; `{HEADER}`, `{CHANNELS}`, `{STEREO_MODE}`,
/// `{STEREO_ENCODING}`, `{HRTF_PREFIX}` and `{HRTF_MODE}` are filled in.
pub const MAIN: &str = r#"{HEADER}

[general]

## channels:
#  Sets the default output channel configuration. If left unspecified, one will
#  try to be detected from the system, with a fallback to stereo. The available
#  values are: mono, stereo, quad, surround51, surround61, surround71,
#  surround714, 3d71, ambi1, ambi2, ambi3, ambi4. Note that the ambi*
#  configurations output ambisonic channels of the given order (using ACN
#  ordering and SN3D normalization by default), which need to be decoded to
#  play correctly on speakers.
channels = {CHANNELS}

## sample-type:
#  Sets the default output sample type. Currently, all mixing is done with
#  32-bit float and converted to the output sample type as needed. Available
#  values are:
#  int8    - signed 8-bit int
#  uint8   - unsigned 8-bit int
#  int16   - signed 16-bit int
#  uint16  - unsigned 16-bit int
#  int32   - signed 32-bit int
#  uint32  - unsigned 32-bit int
#  float32 - 32-bit float
sample-type = float32

## stereo-mode:
#  Specifies if stereo output is treated as being headphones or speakers. With
#  headphones, HRTF or crossfeed filters may be used for better audio quality.
#  Valid settings are auto, speakers, and headphones.
stereo-mode = {STEREO_MODE}

## stereo-encoding:
#  Specifies the default encoding method for stereo output. Valid values are:
#  basic - Standard amplitude panning (aka pair-wise, stereo pair, etc) between
#          -30 and +30 degrees.
#  uhj - Creates a stereo-compatible two-channel UHJ mix, which encodes some
#        continuous surround sound information into stereo output that can be
#        decoded with a surround sound receiver.
#  tsme - Creates a stereo-compatible two-channel surround matrix encoded mix,
#         which encodes some discrete surround sound and height information
#         into the stereo output that can be decoded with a surround sound
#         receiver.
#  hrtf - Uses filters to provide better spatialization of sounds while using
#         stereo headphones.
#  If crossfeed filters are used, basic stereo mixing is used.
stereo-encoding = {STEREO_ENCODING}

## hrtf-mode:
#  Specifies the rendering mode for HRTF processing. Setting the mode to full
#  (default) applies a unique HRIR filter to each source given its relative
#  location, providing the clearest directional response at the cost of the
#  highest CPU usage. Setting the mode to ambi1, ambi2, ambi3, or ambi4 will
#  instead mix to an ambisonic buffer of the given order, then decode that
#  buffer with HRTF filters. Ambi1 has the lowest CPU usage, replacing the per-
#  source HRIR filter for a simple 4-channel panning mix, but retains full 3D
#  placement at the cost of a more diffuse response. Higher ambisonic orders
#  increasingly improve the directional clarity, at the cost of more CPU usage
#  (still less than "full", given some number of active sources).
{HRTF_PREFIX}hrtf-mode = {HRTF_MODE}

## hrtf-paths:
#  Specifies a comma-separated list of paths containing HRTF data sets. The
#  format of the files are described in docs/hrtf.txt. The files within the
#  directories must have the .mhr file extension to be recognized. By default,
#  OS-dependent data paths will be used. They will also be used if the list
#  ends with a comma. On Windows this is:
#  $AppData\openal\hrtf
#  And on other systems, it's (in order):
#  $XDG_DATA_HOME/openal/hrtf  (defaults to $HOME/.local/share/openal/hrtf)
#  $XDG_DATA_DIRS/openal/hrtf  (defaults to /usr/local/share/openal/hrtf and
#                               /usr/share/openal/hrtf)
hrtf-paths = HRTF, OpenAL/HRTF

## period_size:
#  Sets the update period size, in sample frames. This is the number of frames
#  needed for each mixing update. Acceptable values range between 64 and 8192.
#  If left unspecified it will default to 512 sample frames (~10.7ms).
period_size = 1024

## periods:
#  Sets the number of update periods. Higher values create a larger mix ahead,
#  which helps protect against skips when the CPU is under load, but increases
#  the delay between a sound getting mixed and being heard. Acceptable values
#  range between 2 and 16.
periods = 3

## resampler: (global)
#  Selects the default resampler used when mixing sources. Valid values are:
#  point - nearest sample, no interpolation
#  linear - extrapolates samples using a linear slope between samples
#  spline - extrapolates samples using a Catmull-Rom spline
#  gaussian - extrapolates samples using a 4-point Gaussian filter
#  bsinc12 - extrapolates samples using a band-limited Sinc filter (varying
#            between 12 and 24 points, with anti-aliasing)
#  fast_bsinc12 - same as bsinc12, except without interpolation between down-
#                 sampling scales
#  bsinc24 - extrapolates samples using a band-limited Sinc filter (varying
#            between 24 and 48 points, with anti-aliasing)
#  fast_bsinc24 - same as bsinc24, except without interpolation between down-
#                 sampling scales
#  bsinc48 - extrapolates samples using a band-limited Sinc filter (48 points,
#            with anti-aliasing)
#  fast_bsinc48 - same as bsinc48, except without interpolation between down-
#                 sampling scales
resampler = spline

## default-reverb: (global)
#  A reverb preset that applies by default to all sources on send 0
#  (applications that set their own slots on send 0 will override this).
#  Available presets include: None, Generic, PaddedCell, Room, Bathroom,
#  Livingroom, Stoneroom, Auditorium, ConcertHall, Cave, Arena, Hangar,
#  CarpetedHallway, Hallway, StoneCorridor, Alley, Forest, City, Mountains,
#  Quarry, Plain, ParkingLot, SewerPipe, Underwater, Drugged, Dizzy, Psychotic.
default-reverb = Generic"#;

/// Added with the advanced tweaks.
pub const ADVANCED: &str = r#"
# Advanced Audio Limit Expansion

## sources:
#  Sets the maximum number of allocatable sources. Lower values may help for
#  systems with apps that try to play more sounds than the CPU can handle.
sources = 256

## frequency:
#  Sets the default output frequency. If left unspecified it will try to detect
#  a default from the system, otherwise it will fallback to 48000.
frequency = 48000"#;

/// Added for surround speakers.
pub const DECODER: &str = r#"
[decoder]

## hq-mode:
#  Enables a high-quality ambisonic decoder. This mode is capable of frequency-
#  dependent processing, creating a better reproduction of 3D sound rendering
#  over surround sound speakers.
hq-mode = true"#;

/// Always last.
pub const TAIL: &str = r#"
[reverb]

## boost: (global)
#  A global amplification for reverb output, expressed in decibels. The value
#  is logarithmic, so +6 will be a scale of (approximately) 2x, +12 will be a
#  scale of 4x, etc. Similarly, -6 will be about half, and -12 about 1/4th. A
#  value of 0 means no change.
boost = 0

[eax]

## enable: (global)
#  Sets whether to enable EAX extensions or not.
enable = true"#;
