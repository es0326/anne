# 품사 시험지 (중학교 1학년 국어)

교사가 문항을 출제하고, 학생이 링크로 응시하면 결과가 Supabase에 쌓이는 웹앱입니다.
**모든 코드가 `index.html` 한 파일**에 들어 있습니다. (빌드 도구 없음)

```
index.html            앱 전체 (교사 화면 + 학생 화면)
supabase/schema.sql   DB 준비용 SQL — Supabase SQL Editor 에서 한 번 실행
```

## 동작 방식
- 그냥 접속하면 → **교사 화면** (로그인 → 출제 → 결과)
- 주소 뒤에 `?quiz=<시험ID>` 가 붙으면 → **학생 화면** (응시 → 제출)
- 학생용 링크는 교사 화면의 "학생 링크 복사" 버튼이 만들어 줍니다.

## 설정
1. **DB**: Supabase 대시보드 → SQL Editor → `supabase/schema.sql` 붙여넣고 Run (한 번만).
2. **키**: `index.html` 상단 `<script>` 안의 `SUPABASE_URL` / `SUPABASE_ANON_KEY` 확인.
   (publishable/anon 키만. secret 키 금지.)
3. **교사 계정**: Supabase → Authentication → Users → Add user → 이메일·비밀번호,
   "Auto Confirm User" 체크.
4. **배포**: 이 저장소를 GitHub Pages 로 켜면 끝. (Settings → Pages → Deploy from a branch → main / root)

## 배포 후 주소
- 교사: `https://<아이디>.github.io/<저장소>/`
- 학생: 교사 화면에서 링크 복사

## 참고 / 한계
- 학생 응시는 로그인이 없습니다. 중복 제출은 브라우저 저장으로만 막으므로 다른 기기/시크릿 창에서는 다시 제출될 수 있습니다. 결과표에서 확인·정리하세요.
- 정답(`answer`)은 학생에게 전송되지 않습니다. 채점은 DB 함수(`submit_quiz`)가 합니다.
- 시험을 "마감"하면 학생은 응시할 수 없습니다(제출된 결과는 유지).
- 문항 저장 시 해당 시험의 문항은 전체 교체됩니다. 응시가 시작된 뒤에는 문항 순서를 바꾸지 마세요.
