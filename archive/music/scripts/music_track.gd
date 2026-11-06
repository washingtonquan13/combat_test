class_name MusicTrack
extends Resource
## One song, split into its three playable phases — see MusicManager for
## how these actually get played. Either or both of intro/outro can be
## left empty (a track that just loops immediately, or that cuts instead
## of outro-ing); loop is the one phase every real track needs.
##
## Every stem within ONE phase is expected to be the same length — they
## start together and (for loop specifically) are meant to loop as one
## synchronized unit. Mismatched lengths across stems in the same phase
## will drift out of sync; that's a content-authoring requirement, not
## something this resource or MusicManager can enforce.

@export var id: String = ""
@export var intro: Array[MusicStem] = []
@export var loop: Array[MusicStem] = []
@export var outro: Array[MusicStem] = []
