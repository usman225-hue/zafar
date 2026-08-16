"""EPAS v3.6 production compatibility shim.
All active query operations resolve through database.production_queries.
"""
from .production_queries import *  # noqa: F401,F403
