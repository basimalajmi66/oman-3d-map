from uata.knowledge.extract import extract_txt


def test_subtitles_become_timestamped_pieces():
    srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\nIf the candle closes below support, exit.\r\n\r\n" \
          "2\r\n00:01:05,000 --> 00:01:07,000\r\n<i>MACD cross up in an uptrend: buy.</i>\r\n\r\n" \
          "3\r\n01:00:00,000 --> 01:00:02,000\r\nلا تدخل عند الأخبار.\r\n"
    chunks = extract_txt(srt.encode("utf-8-sig"))
    assert [c.location for c in chunks] == ["00:01", "01:05", "1:00:00"]
    assert chunks[1].text == "MACD cross up in an uptrend: buy."


def test_plain_text_with_an_arrow_is_not_subtitles():
    chunks = extract_txt("Rule: RSI < 30 --> buy\n\nmore".encode())
    assert chunks[0].location.startswith("¶1")
