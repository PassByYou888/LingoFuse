# -*- coding: utf-8 -*-
"""
Custom exception hierarchy for the LingoFuse bindings.
"""

class LingoFuseError(Exception):
    """Base exception for all LingoFuse‑related errors."""
    pass

class ConnectionError(LingoFuseError):
    """Raised when connecting to a remote service fails."""
    pass

class TimeoutError(LingoFuseError):
    """Raised when a synchronous call times out."""
    pass

class RegistrationError(LingoFuseError):
    """Raised when API registration fails (e.g., duplicate name)."""
    pass

class SerializationError(LingoFuseError):
    """Raised when serialization or deserialization fails."""
    pass