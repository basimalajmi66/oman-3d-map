"""User-editable settings with validation and safe defaults.

Defaults follow the product specification (section 5):
30-second candles, 1–3 minute suggested duration, manual trading only,
signals only when conditions are met, WAIT otherwise, no repeated signal
without fresh analysis.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

INDICATORS = (
    "price_action",
    "candlesticks",
    "support_resistance",
    "trend",
    "supply_demand",
    "liquidity_zones",
    "moving_averages",
    "rsi",
    "macd",
    "bollinger_bands",
    "atr",
    "volume",
    "momentum",
    "volatility",
    "chart_patterns",
)

ALLOWED_TIMEFRAMES_SEC = (5, 10, 15, 30, 60, 120, 180, 300, 900, 1800, 3600, 14400, 86400)
# longest side a chart image is shrunk to before reading (0 = keep the original size)
ALLOWED_CHART_MAX_SIDE = (0, 800, 1024, 1280, 1600, 1920)
# newest candles kept from a reading (0 = all); strategies need 50+ closed candles, so the minimum is 60
ALLOWED_CHART_MAX_CANDLES = (0, 60, 80, 100, 150, 200)


def _default_indicators() -> dict[str, bool]:
    return {name: True for name in INDICATORS}


class Settings(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)

    # --- trading defaults (section 5)
    candle_timeframe_sec: int = 30
    trade_duration_min_sec: int = Field(60, ge=30, le=3600)
    trade_duration_max_sec: int = Field(180, ge=30, le=3600)
    # Manual is the only mode. The field exists so the UI can display it, but no
    # other value is accepted: the system never executes trades.
    trading_mode: Literal["manual"] = "manual"
    continuous_analysis: bool = False  # analysis only runs while the user enables it
    min_confidence_to_signal: float = Field(0.65, ge=0.5, le=0.95)
    min_data_quality_to_signal: float = Field(0.6, ge=0.3, le=1.0)
    min_confluence_factors: int = Field(3, ge=2, le=10)  # never a single-indicator signal
    signal_cooldown_sec: int = Field(30, ge=0, le=3600)   # no repeat without new analysis

    # --- indicators (section 6) — each one can be switched on/off
    indicators: dict[str, bool] = Field(default_factory=_default_indicators)

    # --- UI
    language: Literal["ar", "en"] = "ar"
    theme: Literal["system", "dark", "light"] = "system"
    panel_always_on_top: bool = True
    panel_opacity: float = Field(0.95, ge=0.3, le=1.0)

    # --- privacy / permissions
    screen_capture_allowed: bool = False  # must be explicitly granted by the user
    # region of the screen to read: None = whole primary monitor
    capture_region: dict[str, int] | None = None
    capture_interval_sec: int = Field(5, ge=2, le=60)  # continuous screen reading cadence
    # chart images: shrink before reading (faster, less memory) and how many of the newest candles to keep
    chart_max_side: int = 1280
    chart_max_candles: int = 100
    external_data_sources_allowed: bool = False
    # optional local speech-to-text model folder (faster-whisper / CTranslate2); never downloaded
    stt_model_path: str | None = None
    # companion devices (phone / tablet) over the local network: off unless the user turns it on
    companion_enabled: bool = False
    companion_port: int = Field(default=8766, ge=1024, le=65535)

    @model_validator(mode="after")
    def _check(self) -> "Settings":
        if self.candle_timeframe_sec not in ALLOWED_TIMEFRAMES_SEC:
            raise ValueError(f"candle_timeframe_sec must be one of {ALLOWED_TIMEFRAMES_SEC}")
        if self.chart_max_side not in ALLOWED_CHART_MAX_SIDE:
            raise ValueError(f"chart_max_side must be one of {ALLOWED_CHART_MAX_SIDE}")
        if self.chart_max_candles not in ALLOWED_CHART_MAX_CANDLES:
            raise ValueError(f"chart_max_candles must be one of {ALLOWED_CHART_MAX_CANDLES}")
        if self.trade_duration_min_sec > self.trade_duration_max_sec:
            raise ValueError("trade_duration_min_sec must be <= trade_duration_max_sec")
        unknown = set(self.indicators) - set(INDICATORS)
        if unknown:
            raise ValueError(f"unknown indicators: {sorted(unknown)}")
        # fill any indicator missing from a partial update
        for name in INDICATORS:
            self.indicators.setdefault(name, True)
        if self.capture_region is not None:
            keys = {"left", "top", "width", "height"}
            if set(self.capture_region) != keys:
                raise ValueError(f"capture_region needs exactly {sorted(keys)}")
            if self.capture_region["width"] < 200 or self.capture_region["height"] < 150:
                raise ValueError("capture_region is too small to contain a readable chart (min 200x150)")
        if sum(self.indicators.values()) < 2:
            raise ValueError("at least two analysis factors must stay enabled")
        return self
