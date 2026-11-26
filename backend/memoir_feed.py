"""
回忆录 / 博客混合信息流（液态玻璃卡片联调用）。

GET /api/v1/memoirs/feed 返回 photo / text / video 三种卡片混合的 Mock 数据。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Annotated, List, Literal, Union

from fastapi import APIRouter
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Pydantic 模型（discriminated union：type 字段区分多态）
# ---------------------------------------------------------------------------


class MemoirBase(BaseModel):
    """三类卡片的公共字段。"""

    id: str
    created_at: datetime = Field(
        ...,
        description="创建时间（ISO8601），前端可用于排序与展示。",
    )


class PhotoMemoir(MemoirBase):
    """Type A：图文卡（对应 Flutter IgStoryCard / 封面图 + 标题）。"""

    type: Literal["photo"] = "photo"
    title: str
    subtitle: str = ""
    image_url: str = Field(..., description="封面图 URL（Mock 可为外链）。")


class TextMemoir(MemoirBase):
    """Type B：纯文本卡（对应 Flutter PureTextGlassCard）。"""

    type: Literal["text"] = "text"
    title: str
    body: str


class VideoMemoir(MemoirBase):
    """Type C：视频卡（对应 Flutter XhsCard：海报 + 播放态占位）。"""

    type: Literal["video"] = "video"
    title: str
    subtitle: str = ""
    poster_url: str = Field(..., description="视频封面图 URL。")
    video_url: str = Field(..., description="视频流或文件 URL（联调占位）。")
    duration_seconds: float | None = Field(
        default=None,
        description="时长（秒），可选。",
    )


MemoirFeedItem = Annotated[
    Union[PhotoMemoir, TextMemoir, VideoMemoir],
    Field(discriminator="type"),
]


def _mock_feed_items() -> List[PhotoMemoir | TextMemoir | VideoMemoir]:
    now = datetime.now(timezone.utc)
    return [
        PhotoMemoir(
            id="mock-photo-1",
            created_at=now - timedelta(hours=5),
            title="海边散步",
            subtitle="周末随拍",
            image_url="https://picsum.photos/id/28/800/1000",
        ),
        TextMemoir(
            id="mock-text-1",
            created_at=now - timedelta(hours=3),
            title="写给明年的自己",
            body="把细碎的日子过成有光的样子。不必着急赶路，偶尔停下来看看云，也很好。",
        ),
        VideoMemoir(
            id="mock-video-1",
            created_at=now - timedelta(hours=1),
            title="城市夜景",
            subtitle="30s 剪辑",
            poster_url="https://picsum.photos/id/122/600/800",
            video_url="https://www.w3schools.com/html/mov_bbb.mp4",
            duration_seconds=28.5,
        ),
        PhotoMemoir(
            id="mock-photo-2",
            created_at=now - timedelta(minutes=40),
            title="咖啡馆一角",
            subtitle="午后",
            image_url="https://picsum.photos/id/1060/800/1000",
        ),
        TextMemoir(
            id="mock-text-2",
            created_at=now - timedelta(minutes=15),
            title="今日一句",
            body="记录是为了在遗忘之前，温柔地留住自己。",
        ),
    ]


router = APIRouter(prefix="/api/v1/memoirs", tags=["memoirs"])


@router.get(
    "/feed",
    response_model=List[MemoirFeedItem],
    summary="混合回忆录信息流（Mock）",
)
def get_memoir_feed() -> List[PhotoMemoir | TextMemoir | VideoMemoir]:
    """返回三种类型混合列表，供 Flutter 液态玻璃卡片联调。"""
    return _mock_feed_items()
