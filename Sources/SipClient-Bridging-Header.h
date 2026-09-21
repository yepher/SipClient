//  SipClient-Bridging-Header.h
//
//  Exposes the vendored vo-amrwbenc AMR-WB encoder to Swift. macOS has a
//  system AMR-WB *decoder* (AudioToolbox, kAudioFormatAMR_WB) but no
//  encoder, so this is the only native dependency in the project.
//
//  Provenance, licensing and what was/wasn't vendored:
//  Sources/RTP/AMRWB/vendor/VENDORED.md

#import "enc_if.h"
