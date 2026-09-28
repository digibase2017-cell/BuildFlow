# Supabase Local — Project SaaS

## Quyền `lead.view.all` — 27/09/2026

Migration 012 bổ sung quyền xem mọi Lead cùng công ty. `lead.view` chỉ xem Lead được phân công; Lead chưa phân công chỉ hiện với `lead.view.all` hoặc Owner/Admin. Hai quyền dùng cùng cơ chế Role và override theo User. RLS kiểm tra riêng phạm vi đọc; `lead.view.all` không cấp quyền sửa, xóa hay phân công. UI Lead nhận cả hai quyền xem.

Đã chạy `npm ci --cache .npm-cache`, `npm run migrations:sync`, `npm run check`, `npm run local:start`, `npm run db:reset`, `npm run db:lint`, `npm run db:test`: 14 migration áp dụng từ DB trống, lint sạch, **227/227 pgTAP PASS**. Bộ HTTP/JWT/concurrency trước Migration 014 đạt **1061/1061**, tự reset database thử nghiệm trước và sau. `npm run app:check` và `npm run app:test` đạt. Các kết quả PASS bên dưới là lịch sử trước Migration 012. Chưa kiểm thử nâng cấp từ database có dữ liệu thật hoặc tải lớn.

## Cập nhật trạng thái Thiết kế — 25/09/2026

Trạng thái tổng Thiết kế hiện là `Chưa bắt đầu`, `Đang thiết kế`, `Chờ khách duyệt`, `Đã duyệt`, `Đã hủy`. Lần gửi có thêm trạng thái `Đã hủy`. Lần gửi mới nhất `Đã gửi` chuyển tổng sang `Chờ khách duyệt`; khi khách yêu cầu sửa (`Đang sửa`), tổng về `Đang thiết kế`; `Sửa xong` chưa coi là đã gửi lại; lần gửi mới nhất `Đã duyệt` chuyển tổng sang `Đã duyệt`. Lần gửi cũ không ghi đè trạng thái lần mới. Trạng thái Project giữ nguyên năm giá trị đã chốt.

Đã sync 10 migration, reset riêng Supabase Local, `npm run check` và `npm run db:lint` đạt, **1058/1058 HTTP/concurrency** đạt ở lượt trước. Harness HTTP đã reset DB thử nghiệm; sau đó tạo lại ba Project mẫu với tài khoản mới (in trong terminal, không lưu mật khẩu trong repo). Giao diện Thiết kế chưa được triển khai. Quyết định mới: hủy một lần gửi không tự hủy toàn bộ Thiết kế; User có quyền tự đổi trạng thái tổng sang `Đã hủy`. Đã thêm bốn assertion và chạy lại `npm run db:test`: **176/176 pgTAP PASS** trên local, không reset dữ liệu mẫu.

## Ứng dụng web local — 25/09/2026

Đã thêm ứng dụng Project tại `app/` với đăng nhập, danh sách/chi tiết, tìm kiếm, bộ lọc Project ẩn cho Owner/Admin và RPC ẩn/bỏ ẩn. Hướng dẫn chạy và giới hạn ở `app/README.md`. Có lệnh `npm run app:demo -- --local-only` tạo dữ liệu mẫu nếu database local trống; lệnh từ chối ghi nếu đã có company. Chạy `npm run app:start` để mở web tại `http://127.0.0.1:4173`.

Docker Desktop đã được mở và `npm run local:start` thành công. Dữ liệu mẫu gồm Owner, Sales và ba Project đã tạo trên local; một Project đang ẩn. Kiểm tra trình duyệt xác nhận Owner đăng nhập, xem Project ẩn và ẩn/bỏ ẩn; Sales đăng nhập chỉ thấy hai Project không ẩn và không có nút ẩn. Đã sửa lỗi hiển thị thanh tiến độ 0% do CSP chặn kiểu inline. `npm run check`, `npm run db:lint` và 157/157 pgTAP đạt sau đó; dữ liệu mẫu vẫn còn. Không đổi migration hay quyết định nghiệp vụ; 1058 kiểm tra HTTP bên dưới thuộc bộ database trước khi thêm ứng dụng.

## Trạng thái ẩn Project — 24/09/2026

Theo quyết định mới, Project không có chức năng xóa. Chỉ Owner/Admin cùng Partner được ẩn hoặc bỏ ẩn Project bằng `set_project_hidden(company,project,hidden)`. Project ẩn chỉ Owner/Admin xem được; dữ liệu thuộc Project và thông báo gắn Project cũng theo phạm vi này. Project ẩn vẫn tính quota. Bỏ ẩn khôi phục quyền truy cập theo Role/thành viên hiện có; Lead và Quote nguồn có phạm vi độc lập.

Đã sửa SQL nguồn 002, 007, 008, 009, 010 và đồng bộ 10 bản migration Supabase. Bỏ quyền grantable `project.delete` khỏi danh mục (còn **56 Permission**). Đã chạy `npm ci`, `migrations:sync`, `npm run check`, `npm run db:reset`, `npm run db:lint` và `npm run db:test`: **157/157 pgTAP PASS** trên local. Test mới `005_hidden_projects.test.sql` kiểm tra ẩn/bỏ ẩn, thành viên không thấy Project ẩn, quota, audit và chặn PATCH/DELETE trực tiếp.

**Kết quả mới nhất: 1058/1058 kiểm tra tích hợp HTTP/concurrency PASS.** Lần chạy đầu dừng ở parser của test Role: câu mô tả quyền `project.delete` đã bỏ bị đếm nhầm thành quyền đang có. Đã sửa parser để chỉ đọc các dòng danh mục quyền, rồi chạy lại thành công. Test ẩn Project xác nhận Owner/Admin xem và bỏ ẩn; các Role khác không đọc được Project ẩn và các bảng con/thông báo gắn với nó; Project ẩn vẫn tính quota; bỏ ẩn khôi phục phạm vi trước đó; Lead/Quote nguồn độc lập. Harness đã reset local trước/sau và xóa fixture Auth/business.

Sau cleanup, `npm run db:lint` không có lỗi, `npm run db:test` đạt 157/157 và `npm run check` xác nhận Docker cùng 10 migration đồng bộ. Hợp đồng HTTP và checklist giao diện nằm trong `PROJECT_HIDDEN_API.md`. Workspace chưa có mã ứng dụng; bước tiếp theo là xác định nơi đặt ứng dụng rồi nối RPC ẩn/bỏ ẩn và kiểm tra luồng hiển thị danh sách/chi tiết. Chỉ dùng database local; chưa triển khai cloud.

## Xóa, phân công, thành viên và nhiều item đồng thời — 24/09/2026

**Kết quả mới nhất: 140/140 pgTAP và 672/672 tích hợp PASS** (457 ca tích hợp trước + 199 kiểm tra quyền/thao tác + 16 kiểm tra tổng hợp nhiều item). Không sửa migration hay quyết định nghiệp vụ ở bước này.

- `scripts/test-permission-actions.mjs`: HTTP JWT riêng của 11 Role kiểm tra DELETE Lead, Quote rỗng, Catalog chưa dùng, Payment, Document, Design round, Acceptance round và item Purchasing/Production/Construction; các bảng con dùng quyền edit theo thiết kế hiện có. Xác minh cả phản hồi HTTP lẫn việc hàng thực sự bị xóa/được giữ lại.
- Mỗi Role thử thêm/xóa Project member và Project Sales; thêm/đổi người phụ trách nghiệm thu; gọi RPC phân công Lead. Xác minh `acceptance.assign` không tự cấp `project.manage_members`, không giao nghiệm thu cho người ngoài Project, không thêm User khác tenant hoặc inactive.
- FK deferred chặn xóa member vẫn còn được giao nghiệm thu và rollback thao tác. Kiểm tra Admin không cấp/hạ Role Admin, Owner làm được; chặn sửa trực tiếp User Owner, sửa quyền Role Owner và dùng override `user.edit`/`role.edit` để vượt quyền quản trị được bảo vệ.
- `scripts/test-module-concurrency.mjs`: 8 lịch tranh chấp có kiểm soát (4 cho Purchasing, 4 cho Production), mỗi lịch có hai kết nối authenticated cùng thay đổi hai item khác nhau trong một module. Xác nhận khóa thực bằng `pg_blocking_pids`, sau đó kiểm tra trạng thái tổng khi cùng hoàn thành, cùng giảm số lượng, chuyển trạng thái ngược chiều và cùng xóa receipt/batch. Cả 16 assertion trạng thái/dữ liệu đạt.
- Entry point vẫn là `npm run test:integration`, reset riêng database `project_saas_local` trước/sau, không truy cập cloud. Những fixture Auth/User mới chỉ dùng trong database thử nghiệm và được reset cùng toàn bộ fixture đã commit.
- Xác minh sau cleanup: `npm run db:lint` không có lỗi; `npm run db:test` đạt 140/140; `npm run check` xác nhận 10 migration khớp nguồn. DB ghi nhận 10 migration, 0 company và 0 Auth User còn lại. Supabase Local vẫn chạy.

Giới hạn: chưa stress test, chưa thử tất cả thứ tự khóa của transaction nhiều câu lệnh hoặc tự động retry deadlock/serialization failure. Chưa có flow ứng dụng đầy đủ cho xóa Project và thu hồi người được giao nghiệm thu: SQL hiện không cấp client DELETE trên `projects`/`acceptance_users`, không thêm quyền này chỉ để test chạy được. Xóa fixture `acceptance_users` trong test dùng postgres có chủ đích; các thao tác nghiệp vụ vẫn chạy HTTP bằng JWT User. Invitation/reset mật khẩu/onboarding, notification/scheduler, report/export và Storage chưa được xác minh đầy đủ.

Bước tiếp theo đề xuất: hoàn thiện thiết kế và triển khai flow onboarding/quản trị Auth local, đồng thời làm rõ API thu hồi phân công nghiệm thu/xóa Project trước khi nối UI. Không suy ra cách xóa dây chuyền hoặc nới quyền từ tên Permission.

## Nguồn Quote, snapshot và ma trận Role — 24/09/2026

**Kết quả tại bước này: 140/140 pgTAP và 457/457 kiểm tra tích hợp PASS, chỉ trên Supabase Local.**

Đã phát hiện và sửa lỗi kỹ thuật: Sales tạo Lead bình thường được nhưng `INSERT ... RETURNING` thất bại với RLS `42501` (ảnh hưởng PostgREST `Prefer: return=representation`). Policy đọc gọi hàm `STABLE` tra lại Lead, trong khi snapshot của hàm chưa thấy bản ghi vừa tạo. Test hồi quy đã tái hiện lỗi trước khi sửa.

- Sửa nguồn `007_functions_rpcs.sql` và `009_rls.sql`: tách `app_private.lead_assignment_scope` cho hàng đang được RLS xét. `can_lead` vẫn kiểm tra Lead tồn tại cho RPC/quan hệ liên quan. Không thay quyền, tenant hoặc quy tắc phân công. Helper mới không được cấp EXECUTE cho client.
- Chạy `npm run migrations:sync`, `npm run check`, reset local và lint thành công. Không tạo Migration 011 vì đây vẫn là bộ cài mới trên database thử nghiệm.
- Thêm `004_lead_returning.test.sql`: 7 assertion, gồm create có/không RETURNING, khả năng thấy Lead mới, helper private và deny `lead.view` vẫn chặn đọc/RETURNING mà không tự thu hồi `lead.create`.
- Thêm `scripts/test-quote-sources.mjs`: **38 kiểm tra** cho Quote nháp/khác Lead/khác tenant; version chưa áp dụng hoặc chỉ áp dụng cho Project khác cùng Lead; item/version không khớp, source NULL một phía, module/Project không khớp, hai direct source. Kiểm tra lịch sử V1 → V2 → V1, nguồn lịch sử vẫn dùng được, snapshot và `contract_value` không tự đổi. Snapshot được tạo bằng dữ liệu test qua SQL như client lưu vào schema; chưa kiểm thử UI sao chép.
- Thêm `scripts/test-role-matrix.mjs`: đối chiếu chính xác bộ quyền mặc định của **11 Role** với tài liệu bàn giao, không lấy SQL seed làm đáp án. HTTP dùng JWT đăng nhập thật riêng từng Role: **12 nhóm đọc/sửa × 11 Role**, **9 nhóm tạo × 11 Role**; mỗi thao tác ghi được kiểm tra lại dữ liệu lưu, kể cả khi API trả 200 nhưng RLS không cập nhật hàng nào. Thêm kiểm tra Project membership, Quote theo phạm vi Lead, deny User và `financial.edit` không có `financial.view` qua RPC.
- Tổng tích hợp: 30 ca cũ + 38 nguồn/snapshot + 389 đối chiếu quyền/đăng nhập/HTTP/phạm vi = **457**. Lần đầu dừng vì lỗi RLS trên; chạy lại sau sửa đạt toàn bộ. Harness vẫn reset local trước/sau để dọn fixture commit và Auth User.
- Xác minh cuối sau cleanup: lint không có lỗi; pgTAP chạy lại **140/140 PASS**; `npm run check` xác nhận 10 migration khớp nguồn; database có 10 migration, 0 company và 0 Auth User. Stack local vẫn chạy.

Chạy lại bằng cùng chuỗi lệnh ở phần bên dưới. `npm run test:integration` tự chạy cả ba file kiểm thử JS; chỉ file `test-integration.mjs` là entry point có kiểm tra project/URL và dọn database.

Giới hạn: ma trận HTTP trên là các endpoint đại diện, không phải đủ 57 Permission qua mọi endpoint. Chưa phủ hết delete/assign/manage_members, invitation/reset mật khẩu/onboarding, report/export, notification, scheduler và API Storage; chưa stress test hoặc kiểm chứng mọi lịch concurrency. Analytics local vẫn tắt. Bước tiếp theo đề xuất: kiểm thử các thao tác delete/assign/manage_members được bảo vệ và tranh chấp nhiều item trong cùng module, sau đó thiết kế kiểm thử onboarding/Auth quản trị.

## Kiểm thử mở rộng trước đó — 24/09/2026

**Kết quả tại bước trước: 133/133 pgTAP và 30/30 kiểm tra HTTP/concurrency PASS trên Supabase Local.** Không sửa migration hoặc quyết định nghiệp vụ ở bước đó.

- Thêm `003_modules_acceptance.test.sql`: 43 assertion cho cả Purchasing, Production và Construction khi số lượng đạt/vượt/ngã dưới ngưỡng, sửa/xóa receipt/batch, thay required quantity; nghiệm thu giữ tiến độ và trạng thái module khác, ngày hoàn thành thủ công, pause/cancel, round mới nhất và xóa round.
- Thêm `scripts/test-integration.mjs`: tạo tài khoản qua Auth HTTP, đăng nhập bằng mật khẩu và refresh token thực; gọi PostgREST với JWT của từng User. Xác minh attribution, scope sau phân công, tenant isolation, anonymous/JWT sai và tài khoản ứng dụng inactive.
- Concurrency dùng các kết nối PostgreSQL độc lập, `SET ROLE authenticated` và JWT subject của User Auth thật. Các ca tranh chấp khóa dùng `pg_blocking_pids` để xác nhận session thứ hai đang chờ session thứ nhất trước khi commit: phân công/mất scope, slot quota Project cuối, đổi trạng thái Lead trong lúc tạo Project, cộng receipt/batch cho cùng item, finalize Quote so với sửa child, hai clone đồng thời. Thêm 8 giao dịch tạo Lead song song để kiểm tra số không trùng.
- Dependency kiểm thử `pg` ghim **8.16.3** trong package.json/package-lock.json. `npm ci` thành công, npm audit không báo vulnerability.
- Fixtures pgTAP dùng transaction rollback. Integration có dữ liệu commit để nhiều session và HTTP nhìn thấy; script reset riêng database local này trước và sau khi chạy, kể cả khi assertion thất bại.
- Sau cleanup của integration, đã chạy lại `npm run db:lint` (không có lỗi), `npm run db:test` (133/133 PASS) và `npm run check` (10 migration khớp hash). Truy vấn xác nhận cuối: 10 migration, 0 company fixture và 0 Auth User còn lại. Supabase Local vẫn đang chạy.

Chạy lại (Docker đang hoạt động và PATH đã cấu hình như bên dưới):

```sh
npm ci
npm run check
npm run local:start
npm run test:integration
npm run db:lint
npm run db:test
```

**`npm run test:integration` xóa dữ liệu database thử nghiệm local trước và sau khi chạy.** Script chỉ chấp nhận `project_id=project_saas_local`, API `127.0.0.1:54321` và DB `127.0.0.1:54322/postgres`; không nhận URL từ xa hoặc dùng project linked. Khóa và token được giữ trong bộ nhớ, không in vào log. Không chạy đồng thời với công việc khác đang dùng dữ liệu trong database này.

Phạm vi còn lại: đây là các ca concurrency có kiểm soát, chưa phải stress/load test hay chứng minh không có deadlock trên mọi thứ tự thao tác. Chưa kiểm thử đầy đủ nguồn Quote khác Project, phân quyền toàn bộ module qua HTTP, invitation/reset mật khẩu/onboarding hoàn chỉnh, nhiều item cùng cập nhật trạng thái module, resume sau pause/cancel và toàn bộ quyền Owner-only. Analytics local vẫn tắt như giải thích bên dưới.

Bước tiếp theo đề xuất: kiểm thử nguồn Quote–Project và snapshot module, sau đó mở rộng ma trận quyền API theo từng Role và các ca tranh chấp nhiều item trong cùng module. Giữ toàn bộ trên local.

## Kết quả kiểm thử lần đầu trên Windows — 24/09/2026

**Supabase Local đã chạy được; Migration 001–010, lint và 90 kiểm tra pgTAP đã PASS.** Chỉ sử dụng project local `project_saas_local`, không link cloud, không deploy, không db push.

- Môi trường: Node.js 24.19.0, npm 11.17.0, Supabase CLI ghim 2.117.0, Docker Desktop 4.92.0 / Engine 29.8.0 (Linux), PostgreSQL image 17.6.1.167.
- `npm ci`: thành công, 8 packages, audit không báo vulnerability. Lần thử trong sandbox không tiến triển nên đã dừng và chạy lại với quyền truy cập mạng phù hợp.
- `npm run check`: PASS; đủ 10 SQL nguồn và 10 bản Supabase, hash khớp toàn bộ.
- `npm run local:start`: thành công sau khi tải images lần đầu.
- `npm run db:reset`: thành công; áp dụng đủ `20260924000001` đến `20260924000010` từ DB trống.
- `npm run db:lint`: PASS, không có lỗi schema `public`/`app_private`.
- `npm run db:test`: lần đầu FAIL tại assertion thứ 16 của workflow vì CTE chứa UPDATE không ở cấp cao nhất; đã sửa cú pháp test, giữ nguyên kiểm tra RLS. Chạy lại PASS: **2 files, 90 tests** (76 workflow/quyền, 14 Quote).
- Đã kiểm tra bảng migration có đủ 10 phiên bản và số công ty fixture còn lại = 0 sau rollback.

Không sửa SQL migration hoặc quyết định nghiệp vụ. Bổ sung 24 assertion: NULL/trùng/inactive trong phân công, giới hạn Admin với Owner/Admin, User inactive, clone Quote/lineage/remap vật liệu, bất biến sau chốt, tổng NULL và half-up rounding. User operations vẫn dùng `authenticated` + JWT subject; postgres chỉ tạo/điều chỉnh fixture và kiểm tra đặc quyền có chủ đích.

Docker Desktop cài theo User và chưa nằm trong PATH của terminal này. Trước khi chạy các lệnh bên dưới trên máy này, dùng PowerShell:

```powershell
$env:Path = "$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin;" + $env:Path
```

`supabase/config.toml` tắt analytics local: Vector của CLI trên Windows sử dụng `host.docker.internal:2375`, nhưng Docker Desktop không mở endpoint này nên Vector lặp restart với `Connection refused`. Không đổi cấu hình Docker host; chức năng thu thập log/analytics local chưa được kiểm thử. Studio và database vẫn dùng các cổng bên dưới.

Đã chạy `npm run local:stop` (giữ backup), `npm run local:start` với cấu hình cuối và chạy lại `npm run db:test`: **90/90 PASS**. Kiểm tra sau restart: 10 container đang chạy, các container có healthcheck đều healthy, không còn Vector lặp restart. Stack được giữ chạy để tiếp tục làm việc.

Ở lần chạy đầu, concurrency, API/Auth HTTP và các nhánh module chưa được kiểm thử. Kết quả mở rộng hiện tại và các giới hạn còn lại nằm ở phần đầu README. PASS của các bộ này không phải xác nhận production-ready.

## Trạng thái bàn giao ban đầu (trước lần kiểm thử Windows)

**Đã chuẩn bị cấu hình và bộ kiểm thử; chưa chạy được Supabase Local.** Môi trường ChatGPT hiện tại không có Docker/Podman, không có Docker socket và không hỗ trợ quyền tạo container. Không có database nào đã được tạo hoặc reset trong phiên này.

Đã thực hiện:

- Cài Supabase CLI **2.117.0**, khóa phiên bản trong package.json/package-lock.json.
- Chạy `supabase init` thành công, tạo cấu hình PostgreSQL 17 mặc định của CLI.
- Thử `supabase start`: thất bại tại kiểm tra Docker, trước khi chạy migration.
- Sao chép chính xác nội dung Migration 001–010 sang tên timestamp Supabase; không sửa quyết định nghiệp vụ hoặc nội dung SQL lần này.
- Chuẩn bị **66 assertion pgTAP** cho workflow chính; mới kiểm tra cú pháp ngoài cùng, **chưa chạy các assertion**.
- Kiểm tra Node, độ khớp file migration, JSON/TOML và ZIP. `npm run check` chủ động trả lỗi khi thiếu Docker.

## Chạy trên máy có Docker

Cần Node.js >=20 và Docker Desktop đang chạy (Linux containers nếu dùng Windows). Không cần tài khoản Supabase Cloud, access token hoặc liên kết project từ xa.

Giải nén, mở terminal trong thư mục có `package.json`, chạy từng lệnh và dừng nếu có lỗi:

```sh
npm ci
npm run check
npm run local:start
npm run db:reset
npm run db:lint
npm run db:test
```

`db:reset` **xóa dữ liệu trong database local của project này** để chạy lại từ DB trống. Chỉ dùng cho môi trường kiểm thử. Các script reset/test/lint chỉ định `--local`; không thêm `--linked`, `--db-url` hoặc chạy `db push` lên hệ thống thật.

`npm run local:start` lần đầu tải Docker images nên có thể mất thời gian. Migration có thể được áp dụng ngay lúc start; nếu start báo lỗi migration, cần sửa lỗi đó trước khi tiếp tục reset/test.

Xem Studio tại `http://127.0.0.1:54323` sau khi start thành công. Dừng dịch vụ bằng:

```sh
npm run local:stop
```

Không đưa thông tin khóa local vào ảnh/log gửi đi. Khi cần hỗ trợ, chỉ gửi thông báo lỗi và tên bước bị lỗi.

## Cấu trúc

- `source_migrations/`: 14 file SQL gốc làm nguồn sửa.
- `supabase/migrations/`: cùng nội dung, tên timestamp hợp lệ cho Supabase CLI.
- `supabase/config.toml`: cấu hình CLI đã init; không chạy seed.sql riêng vì Migration 010 đã chứa defaults.
- `supabase/tests/database/001_workflow.test.sql`: fixture hai công ty và 76 assertion, gói trong BEGIN/ROLLBACK.
- `supabase/tests/database/002_quote_clone.test.sql`: 14 assertion về clone, vật liệu, bất biến và tính tổng; fixture cũng rollback.
- `supabase/tests/database/003_modules_acceptance.test.sql`: 43 assertion về receipt/batch và nghiệm thu; fixture rollback.
- `supabase/tests/database/004_lead_returning.test.sql`: 7 assertion hồi quy RLS INSERT RETURNING.
- `scripts/test-integration.mjs`: entry point 672 kiểm tra tích hợp; reset local trước/sau để dọn fixture commit.
- `scripts/test-quote-sources.mjs`, `scripts/test-role-matrix.mjs`: các phần nguồn/snapshot và Role HTTP được entry point gọi.
- `scripts/test-permission-actions.mjs`, `scripts/test-module-concurrency.mjs`: quyền xóa/phân công/thành viên và tổng hợp nhiều item đồng thời.
- `scripts/preflight.mjs`: kiểm tra Node/Docker và hash migration.
- `scripts/sync-migrations.mjs`: cập nhật bản Supabase từ SQL gốc.
- `MIGRATION_NOTES.md`: thay đổi kỹ thuật và những hạn chế đã biết của bộ SQL.
- `project_handoff_business_decisions.md`: yêu cầu nghiệp vụ chính. Phần trạng thái kỹ thuật trong bản bàn giao này ghi thời điểm trước khi đồng bộ SQL; xem README/MIGRATION_NOTES để biết tiến độ mới hơn. Không coi phần trạng thái cũ là lý do khôi phục schema Sale.

Sau mỗi lần sửa file trong `source_migrations`, chạy:

```sh
npm run migrations:sync
npm run check
npm run db:reset
npm run db:lint
npm run db:test
```

## Phạm vi kiểm thử đã chuẩn bị

- Danh mục 58 quyền sau Migration 012, không có bảng Sale riêng; 11 Role/công ty, không seed User override.
- Lead chưa phân công; phân nhiều người; người tạo mất quyền; cập nhật nhu cầu trên cùng Lead; trưởng nhóm tự thêm/gỡ mình; lead.assign không vượt phạm vi.
- Chặn người nhận khác tenant và giữ nguyên phân công nếu RPC thất bại; cấp riêng allow/deny; danh sách chọn người không mở toàn bộ bảng users.
- Lead Thành công không tự tạo Project; RPC đòi đúng trạng thái/phạm vi; Project Sales là snapshot độc lập.
- Tạo/chốt hai version; áp dụng V1 → V2 → V1; 3 history, 1 active, 2 registry; kiểm tra ràng buộc deferred.
- Nghiệm thu Đạt tự hoàn thành Project; đảo kết quả phục hồi trạng thái và ngày hoàn thành tự động.
- FK cross-tenant dưới quyền ghi đặc quyền; seed lại không khôi phục quyền đã thu hồi; grace và hết grace áp dụng cả Admin.

Đã chạy kiểm tra clone/vật liệu, User inactive, hai trường hợp Admin bị chặn với quyền được bảo vệ và bộ kiểm thử mở rộng mô tả ở đầu README. Chưa bao phủ mọi quyền, mọi nhánh và mọi lịch thực thi đồng thời. Không coi `db:test` PASS là toàn bộ hệ thống đã được xác nhận production-ready.

## Việc tiếp theo

Supabase Local hiện đã thiết lập. Có thể mở Studio tại `http://127.0.0.1:54323`. Bước tiếp theo nên bổ sung kiểm thử concurrency/API và các workflow còn thiếu nêu trên. Khi cần tái lập từ DB trống, mở Docker Desktop và yêu cầu:

> Chạy npm ci, npm run check, rồi khởi động Supabase Local, reset database local, lint và chạy bộ pgTAP. Sửa các lỗi kỹ thuật trong source_migrations, đồng bộ sang supabase/migrations và kiểm thử lại. Đọc tài liệu bàn giao trước, không đổi quyết định nghiệp vụ, không dùng Supabase Cloud. Báo rõ ca nào đã chạy và ca nào chưa; sau khi hoàn tất gợi ý bước tiếp theo.

## Tài liệu chính thức đã đối chiếu

- https://supabase.com/docs/guides/local-development/cli/getting-started
- https://supabase.com/docs/guides/local-development/testing/overview

Đối chiếu ngày 24/09/2026; các cờ reset/test/lint cũng đã kiểm tra bằng `--help` của CLI cài trong bộ này.

## Build Flow — trường Lead/Project mới, 26/09/2026

Migration 011 thêm Source 2/3, loại thực hiện chọn nhiều, loại công trình, một ngân sách nhập tay trên mỗi Lead/Project và lý do thất bại bắt buộc. Option riêng theo công ty được thêm/ẩn trong menu chọn; ẩn không xóa giá trị đã lưu. Khi tạo Project, loại thực hiện và loại công trình được sao chép từ Lead rồi độc lập. Ngân sách Project dùng `project_financials.budget`; Sales/Marketing được thao tác giá trị này theo quyền Lead nguồn qua RPC giới hạn trường. Xem `BUILD_FLOW_LEAD_FIELDS.md` để biết kiểm thử và giới hạn. Phần trước của README ghi lại các mốc kiểm thử lịch sử, không phải trạng thái migration hiện tại.

## Danh sách Lead, 28/09/2026

Migration 012 bổ sung quyền độc lập `lead.view.all` cho Owner/Admin theo mặc định và mở RLS xem mọi Lead trong cùng công ty. Migration 013 chuyển sáu trạng thái Sale sang `Mới`, `Đang chăm sóc`, `Đã hẹn gặp`, `Đã báo giá`, `Thành công`, `Thất bại`. Trang danh sách tại `#/leads` truy vấn từng trang 50 hoặc 100 dòng trên server, tìm tên/số điện thoại và lọc kết hợp, không đếm tổng. Cột phân công dùng RPC `set_lead_assignees`; nút tạo dự án dùng quy trình `create_project_from_lead` hiện có.

Giới hạn hiện tại: schema/API chưa lưu nội dung chăm khách theo Lead để tạo tab “Hoạt động mới nhất”. RPC `list_sale_candidates` ở Migration 014 cho người có `lead.assign` xem riêng tên Sales để chọn; `set_lead_assignees` ở danh sách Lead vẫn chỉ kiểm tra nhân viên cùng công ty đang hoạt động, chưa cưỡng chế phòng Sale.

## Tạo Lead mới — catalog Tỉnh/Thành phố, 28/09/2026

Migration 014 bổ sung option `province` dùng chung theo công ty (ban đầu rỗng), `leads.province` và `user_preferences.default_province` chỉ đọc được bởi chính user. RPC `add_province_option` cho người có `lead.create` hoặc `lead.edit` thêm tỉnh; `list_sale_candidates` chỉ trả nhân viên Sales đang hoạt động của công ty cho người có `lead.assign`. RPC `create_lead_with_assignees` tạo Lead, phân công nhiều Sale và cập nhật tỉnh mặc định trong một transaction, kiểm tra riêng `lead.create` và `lead.assign`; Lead không phân công vẫn tạo được. Trang `#/leads/new` có ba card, không có Trạng thái Sale; database đặt mặc định `Mới`. `Khác` đã được bỏ khỏi lựa chọn Loại thực hiện trên trang tạo.

`set_lead_assignees` dùng ở danh sách Lead vẫn theo phạm vi cũ và chưa kiểm tra department Sales ở database; cần xử lý riêng nếu muốn áp dụng cùng ràng buộc cho mọi con đường phân công. Tab Hoạt động mới nhất vẫn chưa có dữ liệu chăm khách backend.
